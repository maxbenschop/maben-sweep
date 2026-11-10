import Foundation

/// A folder inside a project that could be removed.
public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    public var path: String
    /// Path from the project folder, such as `apps/web/node_modules`.
    public var relativePath: String
    public var name: String
    public var ecosystem: String
    public var kind: ArtifactKind
    public var tier: Tier
    /// Why it isn't `.safe`, in words for the user.
    public var reason: String?
    public var bytes: Int64
    /// The command that brings it back, run in the folder that holds it.
    public var restore: String?
    public var modified: Date?

    public var id: String { path }

    public init(path: String, relativePath: String, name: String, ecosystem: String, kind: ArtifactKind,
                tier: Tier, reason: String? = nil, bytes: Int64 = 0, restore: String? = nil, modified: Date? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.name = name
        self.ecosystem = ecosystem
        self.kind = kind
        self.tier = tier
        self.reason = reason
        self.bytes = bytes
        self.restore = restore
        self.modified = modified
    }
}

/// What a project's last activity was.
public enum ActivitySource: String, Codable, Sendable {
    case commit, files, git, agent, artifacts, unknown

    public var label: String {
        switch self {
        case .commit: "last commit"
        case .files: "file changed"
        case .git: "git activity"
        case .agent: "agent session"
        case .artifacts: "build or install"
        case .unknown: "unknown"
        }
    }
}

/// A project folder with the removable folders found in it.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var isGit: Bool
    public var ecosystems: [String]
    public var artifacts: [Artifact]
    public var lastActivity: Date
    public var activitySource: ActivitySource
    /// A program is running from inside the project right now.
    public var inUse: Bool

    public var id: String { path }

    public init(path: String, name: String, isGit: Bool, ecosystems: [String], artifacts: [Artifact],
                lastActivity: Date, activitySource: ActivitySource, inUse: Bool = false) {
        self.path = path
        self.name = name
        self.isGit = isGit
        self.ecosystems = ecosystems
        self.artifacts = artifacts
        self.lastActivity = lastActivity
        self.activitySource = activitySource
        self.inUse = inUse
    }

    /// The folders automatic cleanup may remove, given the kinds switched on in Settings.
    public func safeArtifacts(kinds: Set<ArtifactKind>) -> [Artifact] {
        artifacts.filter { $0.tier == .safe && kinds.contains($0.kind) }
    }

    public func safeBytes(kinds: Set<ArtifactKind>) -> Int64 {
        safeArtifacts(kinds: kinds).reduce(0) { $0 + $1.bytes }
    }

    public var askArtifacts: [Artifact] { artifacts.filter { $0.tier == .ask } }
    public var totalBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
}

public enum Removal: String, Codable, Sendable {
    /// Removed right away; the space is free immediately.
    case delete
    /// Moved to the Trash; the space is free once the Trash is emptied.
    case trash
}

/// Everything the user can set. The defaults are the ones a new install starts with.
public struct SweepSettings: Codable, Equatable, Sendable {
    /// Off on a new install: Sweep only shows what could go until the user turns this on.
    public var automatic = false
    public var idleDays = 60
    /// Days between the warning and the cleanup. 0 cleans without a warning.
    public var warnDays = 3
    public var onlyOnPower = true
    public var removal = Removal.delete
    public var kinds: Set<ArtifactKind> = [.dependencies, .build, .cache]
    public var lowDiskAlert = true
    public var lowDiskGB = 20
    public var roots: [String] = []
    public var excluded: [String] = []

    public init() {}

    public static let idleChoices = [30, 60, 90, 180]
    public static let warnChoices = [0, 1, 3, 7]
    public static let lowDiskChoices = [10, 20, 50]

    /// Folders that usually hold code, for a new install. Only the ones that exist are used.
    public static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        ["Developer", "Projects", "Code", "code", "dev", "src", "repos", "GitHub", "git", "workspace", "work", "Sites", "Documents"]
            .map { home + "/" + $0 }
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
            .reduce(into: [String]()) { result, path in
                // A case-insensitive disk lists ~/Code and ~/code as the same folder.
                let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
                let key = URL(fileURLWithPath: real).resolvingSymlinksInPath().path.lowercased()
                if !result.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.lowercased() == key }) {
                    result.append(path)
                }
            }
    }
}

/// What Sweep remembers between runs, besides the settings.
public struct SweepState: Codable, Equatable, Sendable {
    /// Projects that are never cleaned.
    public var pinned: Set<String> = []
    /// "Keep for now": counts as activity from that moment.
    public var kept: [String: Date] = [:]
    /// Projects that were warned about, and when they get cleaned.
    public var pending: [String: Date] = [:]
    /// A project's own idle threshold in days.
    public var customIdleDays: [String: Int] = [:]
    public var lastScan: Date?
    public var lastLowDiskAlert: Date?

    public init() {}
}

/// One cleanup, kept so it can be shown and undone.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var relativePath: String
        public var bytes: Int64
        public var restore: String?

        public init(relativePath: String, bytes: Int64, restore: String?) {
            self.relativePath = relativePath
            self.bytes = bytes
            self.restore = restore
        }
    }

    public var id: UUID
    public var date: Date
    public var projectPath: String
    public var projectName: String
    public var items: [Item]
    public var removal: Removal
    public var automatic: Bool

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(id: UUID = UUID(), date: Date, projectPath: String, projectName: String, items: [Item],
                removal: Removal, automatic: Bool) {
        self.id = id
        self.date = date
        self.projectPath = projectPath
        self.projectName = projectName
        self.items = items
        self.removal = removal
        self.automatic = automatic
    }

    /// Shell lines that bring everything in this entry back, one per folder that has a command.
    public var restoreCommands: [String] {
        var seen = Set<String>()
        return items.compactMap { item -> String? in
            guard let restore = item.restore else { return nil }
            let parent = (projectPath as NSString).appendingPathComponent((item.relativePath as NSString).deletingLastPathComponent)
            let line = "cd \(Shell.quote(parent)) && \(restore)"
            return seen.insert(line).inserted ? line : nil
        }
    }
}

public enum Shell {
    /// Quotes a path for a shell command line.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
