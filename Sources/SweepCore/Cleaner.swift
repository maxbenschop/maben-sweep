import Foundation

/// Removes folders. Every folder is checked again at the moment it is removed, so a scan
/// that is hours old can never lead to removing something that changed in the meantime.
public struct Cleaner: Sendable {
    public struct Result: Sendable {
        public var removed: [Artifact] = []
        public var skipped: [(artifact: Artifact, reason: String)] = []
        public var freed: Int64 { removed.reduce(0) { $0 + $1.bytes } }
    }

    public var git: Git?
    public var removal: Removal
    /// The working folders of the running programs, read again before each folder is removed:
    /// removing a big folder takes a while, and a dev server can start in the meantime.
    public var workingDirectories: @Sendable () -> [String] = { ActivityIndex.workingDirectoriesNow() }

    public init(git: Git? = Git.find(), removal: Removal) {
        self.git = git
        self.removal = removal
    }

    /// - Parameter allowAsk: the user clicked on this folder themselves, so `.ask` is enough.
    public func clean(_ artifacts: [Artifact], in project: Project, allowAsk: Bool = false) -> Result {
        var result = Result()
        for artifact in artifacts {
            if ActivityIndex(workingDirectories: workingDirectories()).inUse(project.path) {
                result.skipped.append((artifact, "A program is running in the project"))
                continue
            }
            switch check(artifact, in: project, allowAsk: allowAsk) {
            case .refuse(let reason):
                result.skipped.append((artifact, reason))
            case .remove(let folder, let resolvedProject):
                do {
                    // The folder that passed the checks is the one that goes: the resolved path, not the one from the scan.
                    try Remover.remove(folder, inside: resolvedProject, removal: removal)
                    result.removed.append(artifact)
                } catch {
                    result.skipped.append((artifact, error.localizedDescription))
                }
            }
        }
        return result
    }

    enum Decision {
        case refuse(String)
        /// The resolved folder that passed every check, and the resolved project it is in.
        case remove(String, inside: String)
    }

    /// Why this folder must not be removed right now, or nil when it may.
    func refusal(_ artifact: Artifact, in project: Project, allowAsk: Bool) -> String? {
        if case .refuse(let reason) = check(artifact, in: project, allowAsk: allowAsk) { return reason }
        return nil
    }

    func check(_ artifact: Artifact, in project: Project, allowAsk: Bool) -> Decision {
        // The folder must sit inside the project, and be one of the known names for a known toolchain.
        guard artifact.path.hasPrefix(project.path + "/"), artifact.path.count > project.path.count + 1,
              !artifact.path.contains("/../"), (artifact.path as NSString).lastPathComponent == artifact.name,
              let ecosystem = Rules.ecosystems.first(where: { $0.name == artifact.ecosystem }),
              let rule = ecosystem.artifacts.first(where: { $0.name == artifact.name }) else {
            return .refuse("Not a folder Sweep knows")
        }
        guard FileManager.default.fileExists(atPath: artifact.path) else { return .refuse("Already gone") }
        let verdict = Safety.assess(path: artifact.path, project: project.path, isGit: project.isGit,
                                    ecosystem: ecosystem, rule: rule, git: git)
        guard verdict.tier != .never, let folder = verdict.resolved, let resolvedProject = verdict.resolvedProject else {
            return .refuse(verdict.reason ?? "Not safe to remove")
        }
        if verdict.tier == .ask, !allowAsk { return .refuse(verdict.reason ?? "Needs your OK") }
        return .remove(folder, inside: resolvedProject)
    }

    public static func entry(for result: Result, project: Project, removal: Removal, automatic: Bool, now: Date = Date()) -> HistoryEntry? {
        guard !result.removed.isEmpty else { return nil }
        return HistoryEntry(date: now, projectPath: project.path, projectName: project.name,
                            items: result.removed.map { .init(relativePath: $0.relativePath, bytes: $0.bytes, restore: $0.restore) },
                            removal: removal, automatic: automatic)
    }
}

/// Removes one folder that has just been checked, without trusting its path a second time.
///
/// Between the check and the removal another program could swap a folder on the way for a symlink,
/// and a removal by path would then follow it somewhere else. So the folder's parent is opened
/// first and asked where it really is; the folder is looked at once more through that open parent;
/// and deleting goes name by name from open folders, never following a symlink.
enum Remover {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
        /// The system's words for the last error, such as "Permission denied".
        static func system(_ what: String) -> Failure { Failure("\(what): \(String(cString: strerror(errno)))") }
    }

    /// - Parameters:
    ///   - folder: the resolved path that passed the safety checks
    ///   - project: the resolved project folder it has to be inside
    static func remove(_ folder: String, inside project: String, removal: Removal) throws {
        let parentPath = (folder as NSString).deletingLastPathComponent
        let name = (folder as NSString).lastPathComponent
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.system("Couldn't open the folder it is in") }
        defer { close(parent) }

        // Where the opened folder really is. It has to be the one that was checked, inside the project.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parent, F_GETPATH, &buffer) == 0 else { throw Failure.system("Couldn't check where the folder is") }
        let actual = String(cString: buffer)
        let sensitive = Paths.isCaseSensitive(at: project)
        guard Paths.same(actual, parentPath, caseSensitive: sensitive), Paths.isInside(actual, project, caseSensitive: sensitive) else {
            throw Failure("The folder moved while it was being checked")
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure("Not a real folder any more")
        }

        switch removal {
        case .delete:
            // A deep folder keeps one folder open per level.
            var limit = rlimit()
            if getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 1024 {
                limit.rlim_cur = min(1024, limit.rlim_max)
                setrlimit(RLIMIT_NOFILE, &limit)
            }
            try delete(name, in: parent, device: info.st_dev)
        case .trash:
            // The Trash only takes a path. It is used right after the look above, and by the place
            // the open folder reported, so what is left is the moment between these two lines.
            try FileManager.default.trashItem(at: URL(fileURLWithPath: actual).appendingPathComponent(name), resultingItemURL: nil)
        }
    }

    /// Deletes the folder `name` in the open folder `parent` and everything in it. A symlink is
    /// removed as a link; a folder on another disk (something mounted inside) stops the delete.
    private static func delete(_ name: String, in parent: Int32, device: dev_t) throws {
        let folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Failure.system("Couldn't open \(name)") }
        guard let stream = fdopendir(folder) else { close(folder); throw Failure.system("Couldn't read \(name)") }
        defer { closedir(stream) }   // closes `folder` too
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_dev == device else { throw Failure("\(name) is on another disk") }

        // Read every name first: removing entries while reading a folder can skip some.
        var entries: [(name: String, isFolder: Bool)] = []
        while let entry = readdir(stream) {
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            var isFolder = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var childInfo = stat()
                isFolder = fstatat(folder, child, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 && childInfo.st_mode & S_IFMT == S_IFDIR
            }
            entries.append((child, isFolder))
        }
        for entry in entries {
            if entry.isFolder {
                try delete(entry.name, in: folder, device: device)
            } else if unlinkat(folder, entry.name, 0) != 0, errno != ENOENT {
                throw Failure.system("Couldn't remove \(entry.name)")
            }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw Failure.system("Couldn't remove \(name)") }
    }
}
