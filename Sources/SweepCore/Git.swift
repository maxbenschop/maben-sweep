import Foundation

/// Read-only questions to git. Nothing here changes a repository: optional locks are off,
/// so not even the index is refreshed.
///
/// The folders Sweep looks at are not trusted: a repository's own config, hooks and attributes can
/// name programs to run, and a "partial clone" can make git fetch from a remote. Every question is
/// therefore asked so that none of that can happen, whatever the repository says:
///
/// - Only `ls-files`, `check-ignore`, `rev-list` and `diff-index --cached` are used. None of them
///   pages, opens an editor, checks a signature, or runs a filter, a diff driver or a hook.
/// - The environment is built from nothing, so no `GIT_*` setting of the shell that started the app
///   gets through. The user's own global and system config are trusted and still read.
/// - Every setting that names a program is overridden on the command line, which beats the repository.
/// - No transport is allowed and nothing is fetched (see `environment`).
/// - git's own check on who owns the repository (`safe.directory`) is left as it is.
/// - Every call has a time limit. A call that fails or runs out of time never makes a folder
///   look safer or a project look less used.
public struct Git: Sendable {
    public let binary: String
    /// Seconds one question may take before git, and anything it started, is stopped.
    public var timeout: TimeInterval = 20

    /// Where git is looked for, in this order. Apple's git comes first: it is installed where
    /// only an administrator can change it, while Homebrew's folders can be written by any program
    /// the user runs. `/usr/bin/git` is left out on purpose: on a Mac without the developer tools
    /// it is a stub that opens an "install developer tools" dialog, and on a Mac with them it runs
    /// one of the first two anyway.
    public static let candidates = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]

    public static func find() -> Git? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { Git(binary: $0) }
    }

    public init(binary: String) { self.binary = binary }

    /// Settings given on the command line, where they win from the repository's own config
    /// (and from any file it includes). Each one names a program or a place programs are run from.
    static let overrides = [
        "core.fsmonitor=false", "core.untrackedCache=false",
        "core.hooksPath=/dev/null",
        "core.sshCommand=/usr/bin/false", "core.gitProxy=", "core.askPass=/usr/bin/false",
        "core.pager=cat", "core.editor=/usr/bin/false",
        "core.attributesFile=/dev/null",
        "gpg.program=/usr/bin/false", "gpg.ssh.program=/usr/bin/false", "gpg.x509.program=/usr/bin/false",
        "log.showSignature=false",
        "credential.helper=",
        "diff.external=",
        "uploadpack.packObjectsHook=",
        // The default for every transport. A repository can still allow one by name
        // (`protocol.file.allow`), which is why the environment below closes them all as well.
        "protocol.allow=never",
        "protocol.file.allow=never", "protocol.ext.allow=never", "protocol.ssh.allow=never",
        "protocol.git.allow=never", "protocol.http.allow=never", "protocol.https.allow=never",
        "fetch.recurseSubmodules=false", "submodule.recurse=false",
    ]

    /// Everything git gets from the environment.
    static func environment(for repo: String) -> [String: String] {
        let own = ProcessInfo.processInfo.environment
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": own["HOME"] ?? NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            // A partial clone fetches what it misses from its remote, with a program the repository
            // can name (`remote.<name>.uploadpack`). Newer git (2.50 does, 2.42 doesn't) stops the
            // fetch on this.
            "GIT_NO_LAZY_FETCH": "1",
            // For every git: the only transports allowed are the ones listed here, whatever any config
            // says. The list can't be empty (an empty name would allow a remote helper without a
            // name, and `alias.remote-` in the repository would then be run as that helper), so it
            // holds one name that no helper or program can have, and no alias in the git versions
            // that don't know the setting above.
            "GIT_ALLOW_PROTOCOL": "/",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
            "GIT_SSH_COMMAND": "/usr/bin/false",
            "GIT_PAGER": "cat", "GIT_EDITOR": "/usr/bin/false",
            // Only the repository in this folder answers, never one further up.
            "GIT_CEILING_DIRECTORIES": (repo as NSString).deletingLastPathComponent,
        ]
        // Where the user's own git config may live, and who they are.
        for key in ["XDG_CONFIG_HOME", "USER", "LOGNAME", "TMPDIR"] { env[key] = own[key] }
        return env
    }

    /// Asks git one thing about the repository in `repo`. Not public: every command used has to be
    /// one that can't run anything from the repository (see the list at the top).
    @discardableResult
    func run(_ args: [String], in repo: String, outputLimit: Int = 32 << 20) -> (status: Int32, output: String) {
        let arguments = ["--no-pager", "--no-replace-objects", "--no-optional-locks"]
            + Self.overrides.flatMap { ["-c", $0] }
            // The work tree is this folder, whatever `core.worktree` in the repository claims.
            + ["-C", repo, "--work-tree=" + repo] + args
        let result = Subprocess.run(binary, arguments, environment: Self.environment(for: repo),
                                    timeout: timeout, outputLimit: outputLimit)
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }

    /// Whether git tracks any of these files, or anything inside these folders. Nil when git
    /// can't answer. The paths are taken as written, never as patterns, and on a disk that
    /// ignores case a tracked `Build/` counts for `build`.
    func tracks(_ relativePaths: [String], in repo: String) -> Bool? {
        guard !relativePaths.isEmpty else { return false }
        let magic = Paths.isCaseSensitive(at: repo) ? ":(literal)" : ":(icase,literal)"
        // One name is enough to know, so git is stopped as soon as it prints more than that.
        let result = run(["ls-files", "-z", "--"] + relativePaths.map { magic + $0 }, in: repo, outputLimit: 4096)
        if !result.output.isEmpty { return true }
        return result.status == 0 ? false : nil
    }

    /// True when git tracks at least one file inside `relativePath`. Fails closed: if git can't
    /// answer, the folder counts as tracked.
    public func hasTrackedFiles(_ relativePath: String, in repo: String) -> Bool {
        tracks([relativePath], in: repo) ?? true
    }

    /// True when git tracks at least one of these files. Fails closed the other way: if git can't
    /// answer, none of them counts as tracked.
    public func tracksAny(of relativePaths: [String], in repo: String) -> Bool {
        tracks(relativePaths, in: repo) ?? false
    }

    /// True when a `.gitignore` rule covers the folder.
    public func isIgnored(_ relativePath: String, in repo: String) -> Bool {
        // With the slash git treats it as a folder, which is what `node_modules/` rules match.
        // The `./` keeps a name that starts with a colon from being read as an option.
        run(["check-ignore", "-q", "--", "./" + relativePath + "/"], in: repo).status == 0
    }

    public enum LastCommit: Equatable, Sendable {
        case date(Date)
        /// The repository has no commits yet.
        case none
        /// git couldn't say. Counts as "used just now", so a project is never cleaned on a guess.
        case unknown
    }

    /// The newest commit on any branch.
    public func lastCommit(in repo: String) -> LastCommit {
        // `rev-list` instead of `git log`: it only lists commits. It doesn't format them, and
        // never checks a signature, which `log.showSignature` in a repository can make `git log` do.
        let result = run(["rev-list", "--all", "--max-count=1", "--timestamp", "--no-show-signature"], in: repo, outputLimit: 4096)
        guard result.status == 0 else { return .unknown }
        let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .none }
        guard let seconds = TimeInterval(line.prefix { $0 != " " }) else { return .unknown }
        return .date(Date(timeIntervalSince1970: seconds))
    }

    /// True when the git checkout in `folder` holds nothing of the user's: every commit is also on
    /// a remote or a tag, nothing is staged or stashed, and every file is exactly as git checked it
    /// out, with no file added. This is what a package manager's own checkout of a dependency
    /// looks like until someone works in it. Any doubt, and any answer git can't give, is false.
    public func isPristineCheckout(_ folder: String) -> Bool {
        let local = run(["rev-list", "--max-count=1", "--no-show-signature", "--all", "--not", "--remotes", "--tags"], in: folder, outputLimit: 4096)
        guard local.status == 0, local.output.isEmpty else { return false }
        guard run(["diff-index", "--cached", "--quiet", "HEAD", "--"], in: folder, outputLimit: 4096).status == 0 else { return false }
        // Without exclude options this lists every file git doesn't track, ignored ones too.
        let added = run(["ls-files", "-z", "--others"], in: folder, outputLimit: 4096)
        guard added.status == 0, added.output.isEmpty else { return false }
        // What git remembers of every file it checked out. Comparing that with the disk here,
        // instead of asking git whether a file changed, keeps git from reading file contents,
        // which is where a repository's filter programs would run.
        let index = run(["ls-files", "-z", "--stage", "--debug"], in: folder)
        guard index.status == 0 else { return false }
        return Self.matchesDisk(index.output, in: folder)
    }

    /// Compares the output of `ls-files -z --stage --debug` with the files on disk: each record is
    /// `<mode> <object> <stage>\t<path>\0`, then five lines with what git saw (times, size, flags).
    /// A file is unchanged when its kind, size and modification time are still the same. A file
    /// that was only touched counts as changed, which is the safe side.
    static func matchesDisk(_ listing: String, in folder: String) -> Bool {
        var pieces = listing.components(separatedBy: "\0")[...]
        guard var header = pieces.popFirst() else { return false }
        if header.isEmpty { return pieces.isEmpty }   // nothing tracked, nothing to compare
        while let piece = pieces.popFirst() {
            let lines = piece.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
            guard lines.count >= 5, let tab = header.firstIndex(of: "\t") else { return false }
            let fields = header[..<tab].split(separator: " ")
            let path = String(header[header.index(after: tab)...])
            guard fields.count == 3, fields[2] == "0", !path.isEmpty,
                  let mtime = numbers(in: lines[1], after: "mtime:"), mtime.count == 2,
                  let size = numbers(in: lines[4], after: "size:")?.first else { return false }
            var info = stat()
            guard lstat(folder + "/" + path, &info) == 0 else { return false }
            switch fields[0] {
            case "100644", "100755": guard info.st_mode & S_IFMT == S_IFREG else { return false }
            case "120000": guard info.st_mode & S_IFMT == S_IFLNK else { return false }
            default: return false   // a submodule, or something newer than this code knows
            }
            // git keeps both as 32 bits.
            guard UInt32(truncatingIfNeeded: info.st_size) == size,
                  UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec) == mtime[0],
                  mtime[1] == 0 || UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec) == mtime[1] else { return false }
            header = lines.count > 5 ? String(lines[5]) : ""
        }
        return header.isEmpty
    }

    /// The numbers in a line such as `  mtime: 1700000000:123` or `  size: 12\tflags: 0`, up to the first tab.
    private static func numbers(in line: Substring, after label: String) -> [UInt32]? {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.hasPrefix(label) else { return nil }
        let values = trimmed.dropFirst(label.count).prefix { $0 != "\t" }.split(separator: ":").map { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        return values.contains(nil) ? nil : values.compactMap { $0 }
    }
}
