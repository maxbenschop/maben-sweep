import Foundation

/// Read-only questions to git. Nothing here changes a repository: optional locks are off,
/// so not even the index is refreshed.
public struct Git: Sendable {
    public let binary: String

    /// Finds git without touching `/usr/bin/git`, which opens an "install developer tools" dialog
    /// on a Mac that doesn't have them.
    public static func find() -> Git? {
        let candidates = [
            "/opt/homebrew/bin/git", "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { Git(binary: $0) }
    }

    public init(binary: String) { self.binary = binary }

    @discardableResult
    public func run(_ args: [String], in repo: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // A repository's own config can name programs to run (fsmonitor); never let it.
        process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", repo] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True when git tracks at least one file inside `relativePath`. Fails closed: if git can't
    /// answer, the folder counts as tracked.
    public func hasTrackedFiles(_ relativePath: String, in repo: String) -> Bool {
        let result = run(["ls-files", "-z", "--", relativePath], in: repo)
        return result.status != 0 || !result.output.isEmpty
    }

    /// True when a `.gitignore` rule covers the folder.
    public func isIgnored(_ relativePath: String, in repo: String) -> Bool {
        // With the slash git treats it as a folder, which is what `node_modules/` rules match.
        run(["check-ignore", "-q", "--", relativePath + "/"], in: repo).status == 0
    }

    /// The newest commit on any branch.
    public func lastCommit(in repo: String) -> Date? {
        let result = run(["log", "--all", "-1", "--format=%ct"], in: repo)
        guard result.status == 0, let seconds = TimeInterval(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
