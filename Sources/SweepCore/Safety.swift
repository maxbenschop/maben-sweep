import Foundation

/// Decides whether one folder may be removed. Every check has to pass for `.safe`;
/// anything unexpected ends in `.never`.
public enum Safety {
    public struct Verdict: Equatable, Sendable {
        public let tier: Tier
        public let reason: String?
        public let restore: String?
        /// The folder that was checked, with every symlink on the way to it resolved, and the
        /// project it was found inside. Removing goes by these, so what is removed is what was
        /// checked. Nil when the folder is `.never`.
        public let resolved: String?
        public let resolvedProject: String?

        init(tier: Tier, reason: String?, restore: String?, resolved: String? = nil, resolvedProject: String? = nil) {
            self.tier = tier
            self.reason = reason
            self.restore = restore
            self.resolved = resolved
            self.resolvedProject = resolvedProject
        }
    }

    /// - Parameters:
    ///   - path: the folder, e.g. `/…/site/node_modules`
    ///   - project: the project folder it was found in
    ///   - isGit: the project is a git repository
    ///   - git: nil when git isn't installed, so nothing can be verified
    public static func assess(path: String, project: String, isGit: Bool, ecosystem: Ecosystem, rule: ArtifactRule,
                              git: Git?) -> Verdict {
        let fm = FileManager.default

        // 1. It is a real folder with the expected name, inside the project. A symlink could point anywhere.
        guard (path as NSString).lastPathComponent == rule.name, isRealDirectory(path) else {
            return Verdict(tier: .never, reason: "Not a real folder", restore: nil)
        }
        // From here on every check looks at the resolved folder, the one that would be removed.
        let resolved = Paths.canonical(path)
        let resolvedProject = Paths.canonical(project)
        guard isRealDirectory(resolved), resolved.hasPrefix(resolvedProject + "/") else {
            return Verdict(tier: .never, reason: "Outside the project", restore: nil)
        }
        // On a disk that ignores case `build` also finds a folder that is really called `Build`,
        // which is not a name on the list.
        guard (resolved as NSString).lastPathComponent == rule.name else {
            return Verdict(tier: .never, reason: "Not a real folder", restore: nil)
        }
        let parent = (resolved as NSString).deletingLastPathComponent

        // 2. The file that proves which tool made it sits right next to it.
        let siblings = Set((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
        guard ecosystem.matches(siblings) else {
            return Verdict(tier: .never, reason: "No \(ecosystem.markers[0]) next to it", restore: nil)
        }
        if !rule.signature.isEmpty, !rule.signature.contains(where: { fm.fileExists(atPath: resolved + "/" + $0) }) {
            return Verdict(tier: .never, reason: "Doesn't look like a \(ecosystem.name) folder", restore: nil)
        }
        // Someone's repository inside it is not ours to remove.
        if fm.fileExists(atPath: resolved + "/.git") {
            return Verdict(tier: .never, reason: "Contains a git repository", restore: nil)
        }

        // The command that brings it back.
        let lock = ecosystem.lockfiles.first { siblings.contains($0.file) }
        let restore: String? = rule.kind == .dependencies || rule.kind == .environment ? lock?.restore : ecosystem.rebuild
        func ask(_ reason: String) -> Verdict {
            Verdict(tier: .ask, reason: reason, restore: restore, resolved: resolved, resolvedProject: resolvedProject)
        }

        // 3. Git doesn't track anything inside it, a .gitignore rule covers it, and the project it
        //    belongs to is itself in git.
        var reason: String?
        if isGit {
            guard let git else { return ask("Git isn't installed, so it can't be checked") }
            let relative = String(resolved.dropFirst(resolvedProject.count + 1))
            if git.hasTrackedFiles(relative, in: resolvedProject) {
                return Verdict(tier: .never, reason: "Git tracks files inside it", restore: nil)
            }
            if !git.isIgnored(relative, in: resolvedProject) {
                reason = "Not ignored by git"
            } else {
                // Ignored and untracked can also mean that a whole folder of the repository is
                // ignored, with a project in it that was never committed (`scratch/old-site/dist`).
                // Its output can't be rebuilt from anything git has, so the file that proves the
                // toolchain has to be tracked.
                let folder = (relative as NSString).deletingLastPathComponent
                let markers = ecosystem.markers(in: siblings)
                if !git.tracksAny(of: markers.map { folder.isEmpty ? $0 : folder + "/" + $0 }, in: resolvedProject) {
                    reason = "\(markers.first ?? ecosystem.markers[0]) next to it isn't in git"
                }
            }
        } else {
            reason = "The project isn't in git"
        }

        // 4. Dependencies come back the same only when there's a lockfile.
        if reason == nil, rule.kind == .dependencies, !ecosystem.lockfiles.isEmpty, lock == nil {
            reason = "No lockfile, so a reinstall may give other versions"
        }
        // 5. A folder with an everyday name shows that its toolchain made it.
        if reason == nil, !rule.hasEvidence(folder: resolved, parent: parent, siblings: siblings) {
            reason = "Can't tell what made it"
        }
        if reason == nil, rule.tier == .ask {
            reason = rule.kind == .environment ? "May hold packages installed by hand" : "Always asks"
        }

        // 6. No git repository anywhere inside it, other than a package manager's own untouched
        //    checkout of a dependency. This is the reason shown even when another one applies,
        //    because it is the one that can mean work that exists nowhere else.
        switch repositories(in: resolved) {
        case nil:
            return ask("Too big or unreadable, so it can't be checked for git repositories inside")
        case let found?:
            for folder in found {
                let expected = rule.checkouts.contains { Evidence.fitsPath($0, folder) }
                if !expected || git?.isPristineCheckout(resolved + "/" + folder) != true {
                    return ask(expected ? "A dependency in it (\(folder)) has changes of its own" : "Holds a git repository (\(folder))")
                }
            }
        }

        return Verdict(tier: reason == nil ? .safe : .ask, reason: reason, restore: restore,
                       resolved: resolved, resolvedProject: resolvedProject)
    }

    /// A folder, and not a symlink to one.
    public static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Every folder below `folder` that holds a `.git` (a folder, or the file a worktree or
    /// submodule has), as paths from `folder`. Symlinks aren't followed, and a repository's own
    /// insides aren't searched. Nil when the folder can't be read completely or holds more than
    /// `limit` files and folders: then nobody knows what is in it.
    static func repositories(in folder: String, limit: Int = 3_000_000) -> [String]? {
        var found: [String] = []
        var pending = [""]
        var seen = 0
        while let relative = pending.popLast() {
            let path = relative.isEmpty ? folder : folder + "/" + relative
            guard let directory = opendir(path) else { return nil }
            defer { closedir(directory) }
            var folders: [String] = []
            var isRepository = false
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                seen += 1
                if seen > limit { return nil }
                if name == ".git" { isRepository = true; continue }
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var info = stat()
                    guard lstat(path + "/" + name, &info) == 0 else { return nil }
                    type = info.st_mode & S_IFMT == S_IFDIR ? DT_DIR : DT_REG
                }
                if type == DT_DIR { folders.append(relative.isEmpty ? name : relative + "/" + name) }
            }
            if isRepository {
                found.append(relative)
                if found.count > 10_000 { return nil }
            }
            pending.append(contentsOf: folders)
        }
        return found
    }
}

extension Ecosystem {
    /// The names among `names` that prove this toolchain, e.g. `App.csproj` for `*.csproj`.
    func markers(in names: Set<String>) -> [String] {
        markers.flatMap { marker -> [String] in
            guard marker.hasPrefix("*.") else { return names.contains(marker) ? [marker] : [] }
            let suffix = String(marker.dropFirst())
            return names.filter { $0.hasSuffix(suffix) }.sorted()
        }
    }
}

extension Evidence {
    /// `path` (`checkouts/swift-log`) matches `pattern` (`checkouts/*`), part by part.
    static func fitsPath(_ pattern: String, _ path: String) -> Bool {
        let patterns = pattern.split(separator: "/"), parts = path.split(separator: "/")
        return patterns.count == parts.count && zip(patterns, parts).allSatisfy { fits(String($0), String($1)) }
    }
}
