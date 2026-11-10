import Foundation

/// Decides whether one folder may be removed. Every check has to pass for `.safe`;
/// anything unexpected ends in `.never`.
public enum Safety {
    public struct Verdict: Equatable, Sendable {
        public let tier: Tier
        public let reason: String?
        public let restore: String?
    }

    /// - Parameters:
    ///   - path: the folder, e.g. `/…/site/node_modules`
    ///   - project: the project folder it was found in
    ///   - isGit: the project is a git repository
    ///   - git: nil when git isn't installed, so nothing can be verified
    public static func assess(path: String, project: String, isGit: Bool, ecosystem: Ecosystem, rule: ArtifactRule,
                              git: Git?) -> Verdict {
        let fm = FileManager.default
        let parent = (path as NSString).deletingLastPathComponent

        // 1. It is a real folder with the expected name, inside the project. A symlink could point anywhere.
        guard (path as NSString).lastPathComponent == rule.name, isRealDirectory(path) else {
            return Verdict(tier: .never, reason: "Not a real folder", restore: nil)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedProject = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(resolvedProject + "/") else {
            return Verdict(tier: .never, reason: "Outside the project", restore: nil)
        }

        // 2. The file that proves which tool made it sits right next to it.
        let siblings = Set((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
        guard ecosystem.matches(siblings) else {
            return Verdict(tier: .never, reason: "No \(ecosystem.markers[0]) next to it", restore: nil)
        }
        if !rule.signature.isEmpty, !rule.signature.contains(where: { fm.fileExists(atPath: path + "/" + $0) }) {
            return Verdict(tier: .never, reason: "Doesn't look like a \(ecosystem.name) folder", restore: nil)
        }
        // Someone's repository inside it is not ours to remove.
        if fm.fileExists(atPath: path + "/.git") {
            return Verdict(tier: .never, reason: "Contains a git repository", restore: nil)
        }

        // The command that brings it back.
        let lock = ecosystem.lockfiles.first { siblings.contains($0.file) }
        let restore: String? = rule.kind == .dependencies || rule.kind == .environment ? lock?.restore : ecosystem.rebuild

        // 3. Git doesn't track anything inside it, and a .gitignore rule covers it.
        var reason: String?
        if isGit {
            guard let git else { return Verdict(tier: .ask, reason: "Git isn't installed, so it can't be checked", restore: restore) }
            let relative = String(resolved.dropFirst(resolvedProject.count + 1))
            if git.hasTrackedFiles(relative, in: resolvedProject) {
                return Verdict(tier: .never, reason: "Git tracks files inside it", restore: nil)
            }
            if !git.isIgnored(relative, in: resolvedProject) { reason = "Not ignored by git" }
        } else {
            reason = "The project isn't in git"
        }

        // 4. Dependencies come back the same only when there's a lockfile.
        if reason == nil, rule.kind == .dependencies, !ecosystem.lockfiles.isEmpty, lock == nil {
            reason = "No lockfile, so a reinstall may give other versions"
        }
        if reason == nil, rule.tier == .ask {
            reason = rule.kind == .environment ? "May hold packages installed by hand" : "Always asks"
        }
        return Verdict(tier: reason == nil ? .safe : .ask, reason: reason, restore: restore)
    }

    /// A folder, and not a symlink to one.
    public static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
