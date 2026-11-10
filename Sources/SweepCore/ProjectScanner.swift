import Foundation

/// Finds projects under the chosen folders and the removable folders inside them.
/// Scanning only reads: nothing is changed on disk.
public struct ProjectScanner: Sendable {
    public var roots: [String]
    public var excluded: Set<String>
    public var git: Git?
    public var home: String
    /// How many folders deep a project, or a removable folder inside it, may sit below a root.
    public var maxDepth = 9

    public init(roots: [String], excluded: [String] = [], git: Git? = Git.find(), home: String = NSHomeDirectory()) {
        self.roots = roots.map { Self.clean($0) }
        self.excluded = Set(excluded.map { Self.clean($0) })
        self.git = git
        self.home = home
    }

    static func clean(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// A folder found while walking, before the checks.
    struct Candidate {
        let path: String
        let ecosystem: Ecosystem
        let rule: ArtifactRule
    }

    final class Draft {
        let path: String
        let isGit: Bool
        var ecosystems: [String] = []
        var candidates: [Candidate] = []
        var nested: [String] = []
        init(path: String, isGit: Bool) { self.path = path; self.isGit = isGit }
    }

    /// Sizes from an earlier scan, reused while the folder hasn't changed.
    public typealias SizeCache = [String: CachedSize]
    public struct CachedSize: Codable, Sendable {
        public var bytes: Int64
        public var modified: Date
        public var measured: Date
    }

    public func scan(index: ActivityIndex? = nil, sizes: SizeCache = [:], now: Date = Date(),
                     progress: (@Sendable (String) -> Void)? = nil) -> (projects: [Project], sizes: SizeCache) {
        var drafts: [Draft] = []
        var visited = Set<String>()
        for root in roots where Safety.isRealDirectory(root) {
            walk(root, depth: 0, project: nil, drafts: &drafts, visited: &visited, progress: progress)
        }
        let index = index ?? ActivityIndex.current(home: home)
        let lock = NSLock()
        var projects: [Project] = []
        var newSizes: SizeCache = [:]
        let work = drafts.filter { !$0.candidates.isEmpty }
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let draft = work[i]
            progress?(draft.path)
            guard let (project, measured) = build(draft, index: index, sizes: sizes, now: now) else { return }
            lock.lock()
            projects.append(project)
            newSizes.merge(measured) { _, new in new }
            lock.unlock()
        }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (projects, newSizes)
    }

    /// Looks at one project again, right before cleaning it.
    public func rescan(project path: String, index: ActivityIndex? = nil, now: Date = Date()) -> Project? {
        var drafts: [Draft] = []
        var visited = Set<String>()
        guard Safety.isRealDirectory(path) else { return nil }
        walk(path, depth: 0, project: nil, drafts: &drafts, visited: &visited, progress: nil)
        guard let draft = drafts.first(where: { $0.path == path }) else { return nil }
        return build(draft, index: index ?? ActivityIndex.current(home: home), sizes: [:], now: now)?.0
    }

    private func walk(_ dir: String, depth: Int, project: Draft?, drafts: inout [Draft], visited: inout Set<String>,
                      progress: (@Sendable (String) -> Void)?) {
        guard !excluded.contains(dir), visited.insert(dir).inserted,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let names = Set(entries)
        let matching = Rules.ecosystems.filter { $0.matches(names) }

        var current = project
        if names.contains(".git") {
            let draft = Draft(path: dir, isGit: true)
            project?.nested.append(dir)
            drafts.append(draft)
            current = draft
        } else if current == nil, !matching.isEmpty {
            let draft = Draft(path: dir, isGit: false)
            drafts.append(draft)
            current = draft
        }
        if let current {
            for ecosystem in matching where !current.ecosystems.contains(ecosystem.name) { current.ecosystems.append(ecosystem.name) }
        } else {
            progress?(dir)
        }

        for name in entries.sorted() where name != ".git" {
            let path = dir + "/" + name
            guard Safety.isRealDirectory(path) else { continue }
            // A known folder next to the file that proves what made it: a candidate, and not walked into.
            if let current, let hit = Self.rule(for: name, in: matching) {
                current.candidates.append(Candidate(path: path, ecosystem: hit.0, rule: hit.1))
                continue
            }
            if name.hasPrefix(".") || Rules.neverDescend.contains(name)
                || Rules.bundleExtensions.contains((name as NSString).pathExtension.lowercased())
                || depth + 1 > maxDepth { continue }
            walk(path, depth: depth + 1, project: current, drafts: &drafts, visited: &visited, progress: progress)
        }
    }

    static func rule(for name: String, in ecosystems: [Ecosystem]) -> (Ecosystem, ArtifactRule)? {
        for ecosystem in ecosystems {
            if let rule = ecosystem.artifacts.first(where: { $0.name == name }) { return (ecosystem, rule) }
        }
        return nil
    }

    private func build(_ draft: Draft, index: ActivityIndex, sizes: SizeCache, now: Date) -> (Project, SizeCache)? {
        var artifacts: [Artifact] = []
        var measured: SizeCache = [:]
        for candidate in draft.candidates {
            let verdict = Safety.assess(path: candidate.path, project: draft.path, isGit: draft.isGit,
                                        ecosystem: candidate.ecosystem, rule: candidate.rule, git: git)
            // What can never go isn't offered at all.
            guard verdict.tier != .never else { continue }
            let modified = ActivityIndex.modified(candidate.path) ?? now
            let bytes: Int64
            if let cached = sizes[candidate.path], cached.modified == modified, now.timeIntervalSince(cached.measured) < 7 * 86_400 {
                bytes = cached.bytes
                measured[candidate.path] = cached
            } else {
                bytes = DiskSize.of(candidate.path)
                measured[candidate.path] = CachedSize(bytes: bytes, modified: modified, measured: now)
            }
            artifacts.append(Artifact(path: candidate.path,
                                      relativePath: String(candidate.path.dropFirst(draft.path.count + 1)),
                                      name: candidate.rule.name, ecosystem: candidate.ecosystem.name, kind: candidate.rule.kind,
                                      tier: verdict.tier, reason: verdict.reason, bytes: bytes, restore: verdict.restore,
                                      modified: modified))
        }
        guard !artifacts.isEmpty else { return nil }
        let skip = Set(artifacts.map(\.path) + draft.nested)
        let activity = Activity.last(project: draft.path, isGit: draft.isGit, artifacts: artifacts.map(\.path),
                                     skip: skip, git: git, index: index)
        let project = Project(path: draft.path, name: (draft.path as NSString).lastPathComponent, isGit: draft.isGit,
                              ecosystems: draft.ecosystems, artifacts: artifacts.sorted { $0.bytes > $1.bytes },
                              lastActivity: activity.date, activitySource: activity.source, inUse: index.inUse(draft.path))
        return (project, measured)
    }
}
