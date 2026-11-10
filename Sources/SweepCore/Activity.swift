import Foundation

/// When a project was last worked on. Looked up once per scan and shared by all projects.
public struct ActivityIndex: Sendable {
    /// Working folders of every running program.
    public var workingDirectories: [String]
    /// Claude Code: session folder name → newest session.
    public var claudeSessions: [String: Date]
    /// Codex: working folder → newest session.
    public var codexSessions: [String: Date]

    public init(workingDirectories: [String] = [], claudeSessions: [String: Date] = [:], codexSessions: [String: Date] = [:]) {
        self.workingDirectories = workingDirectories
        self.claudeSessions = claudeSessions
        self.codexSessions = codexSessions
    }

    /// Reads the running programs and the agent logs in `home`.
    public static func current(home: String = NSHomeDirectory()) -> ActivityIndex {
        ActivityIndex(workingDirectories: Processes.workingDirectories(),
                      claudeSessions: claudeSessions(home: home),
                      codexSessions: codexSessions(home: home))
    }

    /// A program is running from the project folder or below it.
    public func inUse(_ project: String) -> Bool {
        workingDirectories.contains { $0 == project || $0.hasPrefix(project + "/") }
    }

    /// The newest agent session started in the project or a folder inside it.
    public func lastAgentSession(_ project: String) -> Date? {
        let key = Self.claudeKey(project)
        var newest: Date?
        // "-Users-me-site" also matches "-Users-me-site-old". That only ever makes a project look
        // more recently used, which is the safe direction.
        for (name, date) in claudeSessions where name == key || name.hasPrefix(key + "-") {
            newest = max(newest ?? date, date)
        }
        for (cwd, date) in codexSessions where cwd == project || cwd.hasPrefix(project + "/") {
            newest = max(newest ?? date, date)
        }
        return newest
    }

    /// Claude Code names a project's session folder after its path, with everything but letters and digits as "-".
    static func claudeKey(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isASCII && (c.isLetter || c.isNumber) ? c : "-"
        })
    }

    static func claudeSessions(home: String) -> [String: Date] {
        let fm = FileManager.default
        var result: [String: Date] = [:]
        let configs = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
        for config in configs {
            let projects = "\(home)/\(config)/projects"
            for name in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let folder = projects + "/" + name
                for file in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".jsonl") {
                    guard let date = modified(folder + "/" + file) else { continue }
                    result[name] = max(result[name] ?? date, date)
                }
            }
        }
        return result
    }

    static func codexSessions(home: String) -> [String: Date] {
        let root = home + "/.codex/sessions"
        guard let files = FileManager.default.enumerator(atPath: root) else { return [:] }
        var result: [String: Date] = [:]
        for case let file as String in files where file.hasSuffix(".jsonl") {
            let path = root + "/" + file
            guard let date = modified(path), let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 8192), as: UTF8.self)
            try? handle.close()
            guard let cwd = codexWorkingDirectory(in: head) else { continue }
            result[cwd] = max(result[cwd] ?? date, date)
        }
        return result
    }

    /// The working folder in the first lines of a Codex session, in the old and the new log format.
    static func codexWorkingDirectory(in head: String) -> String? {
        for (open, close) in [("\"cwd\":\"", "\""), ("<cwd>", "</cwd>")] {
            guard let start = head.range(of: open),
                  let end = head.range(of: close, range: start.upperBound..<head.endIndex) else { continue }
            let value = String(head[start.upperBound..<end.lowerBound])
            if value.hasPrefix("/") { return value }
        }
        return nil
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

enum Processes {
    /// The working folder of every program this user can see.
    static func workingDirectories() -> [String] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var result = Set<String>()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path.count > 1 { result.insert(path) }
        }
        return Array(result)
    }
}

public enum Activity {
    /// The most recent sign that someone worked on the project.
    /// - Parameter skip: folders to leave out (the removable folders and projects nested inside).
    public static func last(project: String, isGit: Bool, artifacts: [String], skip: Set<String>, git: Git?,
                            index: ActivityIndex) -> (date: Date, source: ActivitySource) {
        var best: (date: Date, source: ActivitySource)?
        func consider(_ date: Date?, _ source: ActivitySource) {
            guard let date else { return }
            if best == nil || date > best!.date { best = (date, source) }
        }

        if isGit {
            consider(git?.lastCommit(in: project), .commit)
            // Checkouts, pulls and an editor refreshing the repository all touch these.
            for file in ["HEAD", "logs/HEAD", "index", "FETCH_HEAD"] {
                consider(ActivityIndex.modified(project + "/.git/" + file), .git)
            }
        }
        consider(newestSourceFile(in: project, skip: skip), .files)
        consider(index.lastAgentSession(project), .agent)
        // An install or a build means the project was in use, even if no source changed.
        for artifact in artifacts { consider(ActivityIndex.modified(artifact), .artifacts) }

        // Nothing readable at all: treat it as used right now, so it is never cleaned by mistake.
        return best ?? (Date(), .unknown)
    }

    /// The newest change to a file outside the removable folders. Looks at up to 50,000 files.
    static func newestSourceFile(in project: String, skip: Set<String>) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: project), includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else { return nil }
        var newest: Date?
        var seen = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if values.isDirectory == true, values.isSymbolicLink != true {
                if name == ".git" || Rules.neverDescend.contains(name) || skip.contains(url.path) {
                    walker.skipDescendants()
                }
                continue
            }
            // The Finder rewrites this when a folder is only looked at.
            if name == ".DS_Store" { continue }
            if let date = values.contentModificationDate, newest == nil || date > newest! { newest = date }
            seen += 1
            if seen >= 50_000 { break }
        }
        return newest
    }
}
