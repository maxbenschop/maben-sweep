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

    public init(git: Git? = Git.find(), removal: Removal) {
        self.git = git
        self.removal = removal
    }

    /// - Parameter allowAsk: the user clicked on this folder themselves, so `.ask` is enough.
    public func clean(_ artifacts: [Artifact], in project: Project, allowAsk: Bool = false) -> Result {
        var result = Result()
        for artifact in artifacts {
            if let reason = refusal(artifact, in: project, allowAsk: allowAsk) {
                result.skipped.append((artifact, reason))
                continue
            }
            do {
                let url = URL(fileURLWithPath: artifact.path)
                switch removal {
                case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                case .delete: try FileManager.default.removeItem(at: url)
                }
                result.removed.append(artifact)
            } catch {
                result.skipped.append((artifact, error.localizedDescription))
            }
        }
        return result
    }

    /// Why this folder must not be removed right now, or nil when it may.
    func refusal(_ artifact: Artifact, in project: Project, allowAsk: Bool) -> String? {
        // The folder must sit inside the project, and be one of the known names for a known toolchain.
        guard artifact.path.hasPrefix(project.path + "/"), artifact.path.count > project.path.count + 1,
              !artifact.path.contains("/../"), (artifact.path as NSString).lastPathComponent == artifact.name,
              let ecosystem = Rules.ecosystems.first(where: { $0.name == artifact.ecosystem }),
              let rule = ecosystem.artifacts.first(where: { $0.name == artifact.name }) else {
            return "Not a folder Sweep knows"
        }
        guard FileManager.default.fileExists(atPath: artifact.path) else { return "Already gone" }
        let verdict = Safety.assess(path: artifact.path, project: project.path, isGit: project.isGit,
                                    ecosystem: ecosystem, rule: rule, git: git)
        switch verdict.tier {
        case .safe: return nil
        case .ask: return allowAsk ? nil : (verdict.reason ?? "Needs your OK")
        case .never: return verdict.reason ?? "Not safe to remove"
        }
    }

    public static func entry(for result: Result, project: Project, removal: Removal, automatic: Bool, now: Date = Date()) -> HistoryEntry? {
        guard !result.removed.isEmpty else { return nil }
        return HistoryEntry(date: now, projectPath: project.path, projectName: project.name,
                            items: result.removed.map { .init(relativePath: $0.relativePath, bytes: $0.bytes, restore: $0.restore) },
                            removal: removal, automatic: automatic)
    }
}
