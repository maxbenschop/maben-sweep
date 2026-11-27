import Foundation

/// The parts of installing an update that work without the app, so they are tested: what a
/// genuine copy has to be signed as, swapping the app in place, and the command an administrator
/// runs when the app's folder can't be written by the user.
public enum UpdateInstall {
    public struct Failure: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// What a genuine copy is signed as, in the words `codesign -R` and the Security framework
    /// take: a Developer ID certificate (not a Mac App Store or development one) of our team, our
    /// bundle ID, and notarized by Apple whatever this Mac's Gatekeeper setting is. The check in
    /// the app and the one in the administrator's command both use this text.
    public static func requirement(teamID: String, bundleID: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleID)\" and notarized"
    }

    /// The hidden copy next to the app that a new version is checked in before it takes the app's place.
    public static func staged(for target: URL) -> URL { sibling(of: target, ".update.app") }
    /// The hidden name the running version gets for the moment of the swap.
    public static func old(for target: URL) -> URL { sibling(of: target, ".old.app") }

    private static func sibling(of target: URL, _ suffix: String) -> URL {
        target.deletingLastPathComponent().appendingPathComponent("." + target.deletingPathExtension().lastPathComponent + suffix)
    }

    /// Removes what an interrupted update left next to the app. Called at launch.
    public static func removeLeftovers(nextTo target: URL) {
        for url in [staged(for: target), old(for: target)] { try? FileManager.default.removeItem(at: url) }
    }

    /// Replaces `target` with `newApp` when the user can write the folder it is in.
    ///
    /// The new app is copied next to the target under a hidden name and `verify` runs on that
    /// copy, the one that will be used, not on the download. Then two renames swap them. Whatever
    /// fails, the target is still there afterwards: untouched, or put back.
    ///
    /// - Parameters:
    ///   - verify: throws when the copy isn't a genuine update
    ///   - move: renames one item; a parameter so a test can make it fail
    ///   - discard: what happens to the old version afterwards
    public static func swap(_ target: URL, with newApp: URL, verify: (URL) throws -> Void,
                            move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                            discard: (URL) -> Void = { moveToTrash($0) }) throws {
        let fm = FileManager.default
        let staged = staged(for: target), old = old(for: target)
        removeLeftovers(nextTo: target)
        do {
            try fm.copyItem(at: newApp, to: staged)
            try verify(staged)
            try move(target, old)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try move(staged, target)
        } catch {
            // Put the old version back before anything else.
            try? move(old, target)
            try? fm.removeItem(at: staged)
            throw Failure("Couldn't install the update: \(error.localizedDescription)")
        }
        discard(old)
    }

    /// Moves the version that was replaced to the Trash, so it can be put back by hand; deletes it
    /// when that isn't possible. It gets a name without the leading dot first: the Finder doesn't
    /// show a hidden item in the Trash, which would then look empty and full at the same time.
    public static func moveToTrash(_ old: URL) {
        let fm = FileManager.default
        var item = old
        let visible = old.deletingLastPathComponent().appendingPathComponent(previousName(for: old))
        if (try? fm.moveItem(at: old, to: visible)) != nil { item = visible }
        if (try? fm.trashItem(at: item, resultingItemURL: nil)) == nil { try? fm.removeItem(at: item) }
    }

    /// `.Maben Sweep.old.app` becomes `Maben Sweep (previous version).app`.
    static func previousName(for old: URL) -> String {
        var name = old.deletingPathExtension().lastPathComponent
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasSuffix(".old") { name.removeLast(4) }
        return name + " (previous version)." + old.pathExtension
    }

    /// The shell command that installs an update as an administrator, for an app in a folder the
    /// user can't write. It runs as root, and what this process checked proves nothing to root: the
    /// download is in a folder the user's other programs can write to. So:
    ///
    /// 1. It makes a folder next to the app that only root can open (mode 700 from the moment it
    ///    exists), and copies the new app into it. No other account can touch that copy at any moment.
    /// 2. It gives the copy the owner and group the installed app has, and takes away any
    ///    set-user-ID bit: `ditto` as root keeps mode bits, and a signature doesn't cover them.
    /// 3. It checks that copy itself: the signature against `requirement`, Gatekeeper, and the version.
    /// 4. Two renames swap the copy with the installed app. If the second fails the old one is renamed back.
    /// 5. The folder is removed. On any failure the command ends with an error and the installed
    ///    app is as it was. (Only if the old app can't be renamed back does the folder stay, with
    ///    the old app in it, instead of being removed.)
    ///
    /// The same command as Maben Awake's `Updater.rootInstallCommand`.
    ///
    /// - Parameter token: random text that makes the folder's name; it must be new every time
    public static func rootCommand(newApp: String, target: String, requirement: String, version: String, token: String) -> String {
        let q = Shell.quote
        let name = (target as NSString).lastPathComponent
        let folder = (target as NSString).deletingLastPathComponent + "/." + (name as NSString).deletingPathExtension + ".update." + token
        return [
            "T=\(q(target))",
            "D=\(q(folder))",
            "S=\"$D\"/\(q(name))",
            #"fail() { /bin/rm -rf "$D"; exit 1; }"#,
            // Not `fail`: a folder that was already there isn't ours to remove.
            #"/bin/mkdir -m 700 "$D" || exit 1"#,
            #"/usr/bin/ditto \#(q(newApp)) "$S" || fail"#,
            #"/usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail"#,
            #"/bin/chmod -R ug-s "$S" || fail"#,
            #"/usr/bin/codesign --verify --deep --strict -R=\#(q(requirement)) "$S" || fail"#,
            #"/usr/sbin/spctl --assess --type execute "$S" || fail"#,
            #"[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = \#(q(version)) ] || fail"#,
            #"/bin/mv "$T" "$D/old.app" || fail"#,
            // If the old app can't go back either, it stays in the folder: never `fail` with the only copy in there.
            #"/bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }"#,
            #"/bin/rm -rf "$D""#,
            "exit 0",
        ].joined(separator: "\n")
    }

    /// `text` as an AppleScript string, quotes included, so nothing in it can end the string and
    /// continue as script.
    static func appleScriptString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The AppleScript that runs `command` as an administrator, after asking for the password.
    public static func appleScript(running command: String, prompt: String) -> String {
        "do shell script " + appleScriptString(command) + " with prompt " + appleScriptString(prompt) + " with administrator privileges"
    }
}
