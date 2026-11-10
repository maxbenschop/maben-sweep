import XCTest
@testable import SweepCore

/// Builds real folders and real git repositories in a temporary folder and runs the scanner,
/// the safety checks and the cleaner against them.
final class SweepCoreTests: XCTestCase {
    var root: String!
    let git = Git.find()!
    let fm = FileManager.default
    let emptyIndex = ActivityIndex()

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("sweep-tests-" + UUID().uuidString).path
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    // MARK: - Helpers

    @discardableResult
    func write(_ path: String, _ text: String = "x") -> String {
        let full = root + "/" + path
        try! fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: full, atomically: true, encoding: .utf8)
        return full
    }

    func sh(_ args: [String], in dir: String, date: Date? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git.binary)
        p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-C", root + "/" + dir] + args
        var env = ProcessInfo.processInfo.environment
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp
            env["GIT_COMMITTER_DATE"] = stamp
        }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }

    /// A git repository with one commit of everything that isn't ignored.
    func repo(_ name: String, ignore: String, committed: Date? = nil) {
        write(name + "/.gitignore", ignore)
        sh(["init", "-q"], in: name)
        sh(["add", "-A"], in: name)
        sh(["commit", "-q", "-m", "first"], in: name, date: committed)
    }

    /// Makes every file and folder under `name` look last changed `days` ago.
    func age(_ name: String, days: Double) {
        let date = Date().addingTimeInterval(-days * 86_400)
        let base = root + "/" + name
        var paths = [base]
        if let walker = fm.enumerator(atPath: base) { for case let p as String in walker { paths.append(base + "/" + p) } }
        for path in paths { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    }

    func scan(_ roots: [String]? = nil, excluded: [String] = [], index: ActivityIndex? = nil) -> [Project] {
        ProjectScanner(roots: roots ?? [root], excluded: excluded, git: git, home: root).scan(index: index ?? emptyIndex).projects
    }

    func artifact(_ projects: [Project], _ project: String, _ relative: String) -> Artifact? {
        projects.first { $0.name == project }?.artifacts.first { $0.relativePath == relative }
    }

    /// A Node project in git with node_modules and .next ignored and a lockfile.
    func nodeProject(_ name: String = "site", lockfile: Bool = true, ignore: String = "node_modules/\n.next/\n", committed: Date? = nil) {
        write(name + "/package.json", "{}")
        if lockfile { write(name + "/package-lock.json", "{}") }
        write(name + "/src/index.js", "console.log(1)")
        write(name + "/node_modules/left-pad/index.js", String(repeating: "a", count: 20_000))
        write(name + "/.next/cache/data", String(repeating: "b", count: 20_000))
        repo(name, ignore: ignore, committed: committed)
    }

    // MARK: - Safety: what may go

    func testIgnoredDependenciesWithLockfileAreSafe() {
        nodeProject()
        let projects = scan()
        XCTAssertEqual(projects.count, 1)
        let modules = artifact(projects, "site", "node_modules")
        XCTAssertEqual(modules?.tier, .safe)
        XCTAssertEqual(modules?.restore, "npm install")
        XCTAssertEqual(modules?.kind, .dependencies)
        XCTAssertGreaterThan(modules?.bytes ?? 0, 0)
        XCTAssertEqual(artifact(projects, "site", ".next")?.tier, .safe)
        XCTAssertEqual(projects[0].ecosystems, ["Node"])
        XCTAssertTrue(projects[0].isGit)
    }

    func testRestoreCommandFollowsTheLockfile() {
        write("a/package.json", "{}"); write("a/pnpm-lock.yaml"); write("a/node_modules/x/i.js")
        repo("a", ignore: "node_modules/\n")
        write("b/package.json", "{}"); write("b/yarn.lock"); write("b/node_modules/x/i.js")
        repo("b", ignore: "node_modules/\n")
        let projects = scan()
        XCTAssertEqual(artifact(projects, "a", "node_modules")?.restore, "pnpm install")
        XCTAssertEqual(artifact(projects, "b", "node_modules")?.restore, "yarn install")
    }

    func testNoLockfileAsks() {
        nodeProject(lockfile: false)
        let modules = artifact(scan(), "site", "node_modules")
        XCTAssertEqual(modules?.tier, .ask)
        XCTAssertTrue(modules?.reason?.contains("lockfile") ?? false)
        // Build output doesn't need a lockfile.
        XCTAssertEqual(artifact(scan(), "site", ".next")?.tier, .safe)
    }

    func testNotIgnoredAsks() {
        nodeProject(ignore: ".next/\n")
        // node_modules was committed by `add -A`; remove it from git again so it is untracked but not ignored.
        sh(["rm", "-r", "-q", "--cached", "node_modules"], in: "site")
        sh(["commit", "-q", "-m", "untrack"], in: "site")
        let modules = artifact(scan(), "site", "node_modules")
        XCTAssertEqual(modules?.tier, .ask)
        XCTAssertEqual(modules?.reason, "Not ignored by git")
    }

    func testFolderWithTrackedFilesIsNeverOffered() {
        write("lib/package.json", "{}")
        write("lib/package-lock.json", "{}")
        write("lib/dist/bundle.js", "shipped")
        write("lib/node_modules/x/index.js")
        repo("lib", ignore: "node_modules/\n")   // dist is committed
        let projects = scan()
        XCTAssertNil(artifact(projects, "lib", "dist"), "a committed dist folder must not be offered")
        XCTAssertNotNil(artifact(projects, "lib", "node_modules"))
    }

    func testIgnoredFolderWithOneForceAddedFileIsNeverOffered() {
        nodeProject()
        write("site/.next/keep.txt", "important")
        sh(["add", "-f", ".next/keep.txt"], in: "site")
        sh(["commit", "-q", "-m", "keep"], in: "site")
        XCTAssertNil(artifact(scan(), "site", ".next"))
    }

    func testNameWithoutItsMarkerFileIsIgnored() {
        write("notes/node_modules/x/index.js")        // no package.json
        write("notes/target/thing.txt")               // no Cargo.toml
        write("notes/readme.md")
        repo("notes", ignore: "node_modules/\ntarget/\n")
        XCTAssertTrue(scan().isEmpty)
    }

    func testSymlinkedFolderIsIgnored() throws {
        write("real/data/file.txt", "precious")
        write("site/package.json", "{}")
        write("site/package-lock.json", "{}")
        try fm.createSymbolicLink(atPath: root + "/site/node_modules", withDestinationPath: root + "/real/data")
        repo("site", ignore: "node_modules\n")
        XCTAssertTrue(scan().isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: root + "/real/data/file.txt"))
    }

    func testProjectOutsideGitAsks() {
        write("loose/package.json", "{}")
        write("loose/package-lock.json", "{}")
        write("loose/node_modules/x/index.js")
        let projects = scan()
        XCTAssertEqual(projects.first?.isGit, false)
        XCTAssertEqual(artifact(projects, "loose", "node_modules")?.tier, .ask)
        XCTAssertEqual(artifact(projects, "loose", "node_modules")?.reason, "The project isn't in git")
    }

    func testRustTargetNeedsItsSignature() {
        write("fake/Cargo.toml"); write("fake/target/my-notes.txt")
        repo("fake", ignore: "target/\n")
        write("real/Cargo.toml"); write("real/target/CACHEDIR.TAG"); write("real/target/debug/app")
        repo("real", ignore: "target/\n")
        let projects = scan()
        XCTAssertNil(artifact(projects, "fake", "target"))
        XCTAssertEqual(artifact(projects, "real", "target")?.tier, .safe)
        XCTAssertEqual(artifact(projects, "real", "target")?.restore, "cargo build")
    }

    func testPythonEnvironmentAlwaysAsks() {
        write("api/requirements.txt", "flask")
        write("api/.venv/pyvenv.cfg", "home = /usr/bin")
        write("api/.venv/lib/site.py")
        write("api/.pytest_cache/v/cache")
        repo("api", ignore: ".venv/\n.pytest_cache/\n")
        let projects = scan()
        XCTAssertEqual(artifact(projects, "api", ".venv")?.tier, .ask)
        XCTAssertEqual(artifact(projects, "api", ".venv")?.kind, .environment)
        XCTAssertEqual(artifact(projects, "api", ".pytest_cache")?.tier, .safe)
        // An environment is not removed by automatic cleanup, whatever the settings.
        XCTAssertFalse(projects[0].safeArtifacts(kinds: Set(ArtifactKind.allCases)).contains { $0.name == ".venv" })
    }

    func testFolderHoldingAGitRepositoryIsNeverOffered() {
        nodeProject()
        write("site/node_modules/.git/HEAD", "ref: refs/heads/main")
        XCTAssertNil(artifact(scan(), "site", "node_modules"))
    }

    func testWithoutGitNothingIsSafe() {
        nodeProject()
        let projects = ProjectScanner(roots: [root], git: nil, home: root).scan(index: emptyIndex).projects
        XCTAssertEqual(artifact(projects, "site", "node_modules")?.tier, .ask)
    }

    // MARK: - Scanner

    func testMonorepoPackagesAreFoundInsideOneProject() {
        write("mono/package.json", "{}"); write("mono/pnpm-lock.yaml")
        write("mono/node_modules/a/i.js")
        write("mono/apps/web/package.json", "{}")
        write("mono/apps/web/node_modules/b/i.js")
        write("mono/apps/web/.next/cache")
        repo("mono", ignore: "node_modules/\n.next/\n")
        let projects = scan()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(Set(projects[0].artifacts.map(\.relativePath)), ["node_modules", "apps/web/node_modules", "apps/web/.next"])
        // The nested package has no lockfile of its own, so its dependencies ask.
        XCTAssertEqual(artifact(projects, "mono", "apps/web/node_modules")?.tier, .ask)
        XCTAssertEqual(artifact(projects, "mono", "node_modules")?.tier, .safe)
    }

    func testNestedRepositoryIsItsOwnProject() {
        nodeProject("outer")
        write("outer/tools/inner/package.json", "{}")
        write("outer/tools/inner/package-lock.json", "{}")
        write("outer/tools/inner/node_modules/x/i.js")
        repo("outer/tools/inner", ignore: "node_modules/\n")
        let projects = scan()
        XCTAssertEqual(Set(projects.map(\.name)), ["outer", "inner"])
        XCTAssertEqual(artifact(projects, "inner", "node_modules")?.tier, .safe)
    }

    func testExcludedFolderIsSkipped() {
        nodeProject("a")
        nodeProject("b")
        XCTAssertEqual(scan(excluded: [root + "/b"]).map(\.name), ["a"])
    }

    func testMissingRootIsSkipped() {
        nodeProject()
        XCTAssertEqual(scan([root + "/nope", root]).count, 1)
    }

    func testScanningChangesNothing() {
        nodeProject()
        age("site", days: 100)
        func snapshot() -> [String: Date] {
            var result: [String: Date] = [:]
            for case let p as String in fm.enumerator(atPath: root)! {
                result[p] = (try? fm.attributesOfItem(atPath: root + "/" + p))?[.modificationDate] as? Date
            }
            return result
        }
        let before = snapshot()
        _ = scan()
        XCTAssertEqual(before, snapshot())
    }

    func testHardLinkedFilesAreCountedOnce() throws {
        let file = write("store/big.bin", String(repeating: "z", count: 400_000))
        let single = DiskSize.of(root + "/store")
        try fm.linkItem(atPath: file, toPath: root + "/store/copy1.bin")
        try fm.linkItem(atPath: file, toPath: root + "/store/copy2.bin")
        XCTAssertLessThan(DiskSize.of(root + "/store"), single + 100_000)
        XCTAssertGreaterThan(single, 300_000)
    }

    // MARK: - Activity

    func testOldProjectIsIdleAndAFreshEditMakesItActive() {
        let old = Date().addingTimeInterval(-100 * 86_400)
        nodeProject(committed: old)
        age("site", days: 100)
        var project = scan()[0]
        XCTAssertEqual(Format.days(since: project.lastActivity), 100)

        write("site/src/index.js", "console.log(2)")   // uncommitted work
        project = scan()[0]
        XCTAssertEqual(Format.days(since: project.lastActivity), 0)
        XCTAssertEqual(project.activitySource, .files)
    }

    func testChangesInsideRemovableFoldersDontCount() {
        nodeProject(committed: Date().addingTimeInterval(-100 * 86_400))
        age("site", days: 100)
        // A file deep inside node_modules changes, the folder itself doesn't.
        let deep = root + "/site/node_modules/left-pad/index.js"
        try! fm.setAttributes([.modificationDate: Date()], ofItemAtPath: deep)
        XCTAssertEqual(Format.days(since: scan()[0].lastActivity), 100)
    }

    func testFinderMetadataDoesntCount() {
        nodeProject(committed: Date().addingTimeInterval(-100 * 86_400))
        age("site", days: 100)
        write("site/.DS_Store", "finder")
        XCTAssertEqual(Format.days(since: scan()[0].lastActivity), 100)
    }

    func testRecentCommitOnAnotherBranchCounts() {
        nodeProject(committed: Date().addingTimeInterval(-100 * 86_400))
        sh(["checkout", "-q", "-b", "feature"], in: "site")
        write("site/src/new.js")
        sh(["add", "-A"], in: "site")
        sh(["commit", "-q", "-m", "work"], in: "site", date: Date().addingTimeInterval(-5 * 86_400))
        sh(["checkout", "-q", "-"], in: "site")
        age("site", days: 100)
        let project = scan()[0]
        XCTAssertEqual(Format.days(since: project.lastActivity), 5)
        XCTAssertEqual(project.activitySource, .commit)
    }

    func testAgentSessionCounts() {
        nodeProject(committed: Date().addingTimeInterval(-100 * 86_400))
        age("site", days: 100)
        let recent = Date().addingTimeInterval(-2 * 86_400)
        let index = ActivityIndex(claudeSessions: [ActivityIndex.claudeKey(root + "/site"): recent])
        let project = scan(index: index)[0]
        XCTAssertEqual(project.activitySource, .agent)
        XCTAssertEqual(Format.days(since: project.lastActivity), 2)
    }

    func testAgentLogsAreReadFromDisk() {
        let project = "/Users/me/My Projects/site.app"
        XCTAssertEqual(ActivityIndex.claudeKey(project), "-Users-me-My-Projects-site-app")
        let session = write("home/.claude/projects/-Users-me-My-Projects-site-app/abc.jsonl", "{}")
        write("home/.codex/sessions/2026/01/02/rollout-new.jsonl", #"{"type":"session_meta","payload":{"id":"1","cwd":"/Users/me/api","originator":"codex"}}"#)
        write("home/.codex/sessions/2025/09/05/rollout-old.jsonl", "{\"id\":\"2\"}\n{\"text\":\"<environment_context>\\n  <cwd>/Users/me/old tool</cwd>\\n\"}")
        let index = ActivityIndex(claudeSessions: ActivityIndex.claudeSessions(home: root + "/home"),
                                  codexSessions: ActivityIndex.codexSessions(home: root + "/home"))
        XCTAssertEqual(index.lastAgentSession(project), ActivityIndex.modified(session))
        XCTAssertNotNil(index.lastAgentSession("/Users/me/api"))
        XCTAssertNotNil(index.lastAgentSession("/Users/me/old tool"))
        XCTAssertNil(index.lastAgentSession("/Users/me/other"))
    }

    func testRunningProgramMarksProjectInUse() {
        nodeProject()
        let index = ActivityIndex(workingDirectories: [root + "/site/src"])
        XCTAssertTrue(scan(index: index)[0].inUse)
        XCTAssertFalse(scan(index: ActivityIndex(workingDirectories: [root + "/site-other"]))[0].inUse)
    }

    func testThisProcessShowsUpInTheWorkingDirectories() {
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).resolvingSymlinksInPath().path
        let found = Processes.workingDirectories().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertTrue(found.contains(cwd))
    }

    // MARK: - Cleaner

    func testCleaningRemovesOnlyTheSafeFoldersAndLeavesGitClean() {
        nodeProject()
        write("site/.env", "SECRET=1")              // ignored below, and never a known folder
        write("site/uploads/photo.jpg", "jpeg")
        sh(["add", "-A"], in: "site"); sh(["commit", "-q", "-m", "more"], in: "site")
        let project = scan()[0]
        let result = Cleaner(git: git, removal: .delete).clean(project.safeArtifacts(kinds: Set(ArtifactKind.allCases)), in: project)

        XCTAssertEqual(Set(result.removed.map(\.name)), ["node_modules", ".next"])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertGreaterThan(result.freed, 0)
        XCTAssertFalse(fm.fileExists(atPath: root + "/site/node_modules"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/site/.next"))
        for kept in ["package.json", "package-lock.json", "src/index.js", ".env", "uploads/photo.jpg", ".git/HEAD"] {
            XCTAssertTrue(fm.fileExists(atPath: root + "/site/" + kept), kept)
        }
        // Every file git tracks is still there and unchanged.
        XCTAssertEqual(git.run(["status", "--porcelain"], in: root + "/site").output, "")
        XCTAssertEqual(git.run(["ls-files", "--deleted"], in: root + "/site").output, "")
    }

    func testAskFoldersNeedAClick() {
        nodeProject(lockfile: false)
        let project = scan()[0]
        let modules = project.artifacts.first { $0.name == "node_modules" }!
        let cleaner = Cleaner(git: git, removal: .delete)
        let refused = cleaner.clean([modules], in: project)
        XCTAssertTrue(refused.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: modules.path))
        let allowed = cleaner.clean([modules], in: project, allowAsk: true)
        XCTAssertEqual(allowed.removed.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: modules.path))
    }

    func testFolderThatBecameTrackedAfterTheScanIsRefused() {
        nodeProject()
        let project = scan()[0]
        write("site/.next/keep.txt", "important")
        sh(["add", "-f", ".next/keep.txt"], in: "site")
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project, allowAsk: true)
        XCTAssertEqual(result.removed.map(\.name), ["node_modules"])
        XCTAssertEqual(result.skipped.first?.reason, "Git tracks files inside it")
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/.next/keep.txt"))
    }

    func testFolderReplacedByASymlinkAfterTheScanIsRefused() throws {
        nodeProject()
        write("precious/thesis.txt", "years of work")
        let project = scan()[0]
        try fm.removeItem(atPath: root + "/site/node_modules")
        try fm.createSymbolicLink(atPath: root + "/site/node_modules", withDestinationPath: root + "/precious")
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project, allowAsk: true)
        XCTAssertFalse(result.removed.contains { $0.name == "node_modules" })
        XCTAssertTrue(fm.fileExists(atPath: root + "/precious/thesis.txt"))
    }

    func testMadeUpPathsAreRefused() {
        nodeProject()
        write("site/src/secret/file.txt")
        write("other/node_modules/x.js")
        let project = scan()[0]
        let cleaner = Cleaner(git: git, removal: .delete)
        let bogus = [
            Artifact(path: root + "/site/src", relativePath: "src", name: "src", ecosystem: "Node", kind: .build, tier: .safe),
            Artifact(path: root + "/other/node_modules", relativePath: "../other/node_modules", name: "node_modules", ecosystem: "Node", kind: .dependencies, tier: .safe),
            Artifact(path: root + "/site/node_modules/../src", relativePath: "src", name: "src", ecosystem: "Node", kind: .build, tier: .safe),
            Artifact(path: root + "/site", relativePath: "", name: "site", ecosystem: "Node", kind: .build, tier: .safe),
            Artifact(path: root + "/site/.git", relativePath: ".git", name: ".git", ecosystem: "Node", kind: .cache, tier: .safe),
            Artifact(path: root + "/site/node_modules", relativePath: "node_modules", name: "node_modules", ecosystem: "Made up", kind: .dependencies, tier: .safe),
        ]
        let result = cleaner.clean(bogus, in: project, allowAsk: true)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.skipped.count, bogus.count)
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/src/secret/file.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/other/node_modules/x.js"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/.git/HEAD"))
    }

    func testHistoryEntryAndRestoreCommands() {
        write("mono/package.json", "{}"); write("mono/pnpm-lock.yaml"); write("mono/node_modules/a/i.js")
        write("mono/it's here/package.json", "{}"); write("mono/it's here/yarn.lock"); write("mono/it's here/node_modules/b/i.js")
        write("mono/.next/cache")
        repo("mono", ignore: "node_modules/\n.next/\n")
        let project = scan()[0]
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project)
        let entry = Cleaner.entry(for: result, project: project, removal: .delete, automatic: true)!
        XCTAssertEqual(entry.items.count, 3)
        XCTAssertEqual(entry.bytes, result.freed)
        XCTAssertEqual(Set(entry.restoreCommands), [
            "cd '\(root!)/mono' && pnpm install",
            "cd '\(root!)/mono/it'\\''s here' && yarn install",
        ])
        XCTAssertNil(Cleaner.entry(for: Cleaner.Result(), project: project, removal: .delete, automatic: true))
    }

    // MARK: - Planner

    func project(_ path: String, idle days: Double, tier: Tier = .safe, kind: ArtifactKind = .dependencies, inUse: Bool = false) -> Project {
        Project(path: path, name: (path as NSString).lastPathComponent, isGit: true, ecosystems: ["Node"],
                artifacts: [Artifact(path: path + "/node_modules", relativePath: "node_modules", name: "node_modules",
                                     ecosystem: "Node", kind: kind, tier: tier, bytes: 1_000_000)],
                lastActivity: Date().addingTimeInterval(-days * 86_400), activitySource: .commit, inUse: inUse)
    }

    func testDefaultsOfANewInstall() {
        let s = SweepSettings()
        XCTAssertFalse(s.automatic, "a new install must only show what could go")
        XCTAssertEqual(s.idleDays, 60)
        XCTAssertEqual(s.warnDays, 3)
        XCTAssertTrue(s.onlyOnPower)
        XCTAssertEqual(s.removal, .delete)
        XCTAssertEqual(s.kinds, [.dependencies, .build, .cache])
        XCTAssertFalse(s.kinds.contains(.environment))
        XCTAssertTrue(s.lowDiskAlert)
        XCTAssertEqual(s.lowDiskGB, 20)
        XCTAssertTrue(SweepSettings.idleChoices.contains(s.idleDays))
        XCTAssertTrue(SweepSettings.warnChoices.contains(s.warnDays))
        XCTAssertTrue(SweepSettings.lowDiskChoices.contains(s.lowDiskGB))
    }

    func testStatuses() {
        var settings = SweepSettings()
        var state = SweepState()
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 10), settings: settings, state: state), .active(daysLeft: 50))
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61), settings: settings, state: state), .idle(days: 61))
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61, inUse: true), settings: settings, state: state), .inUse)
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61, tier: .ask), settings: settings, state: state), .nothingSafe)
        settings.kinds = [.build]
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61), settings: settings, state: state), .nothingSafe)
        settings.kinds = [.dependencies]
        state.pinned = ["/p/a"]
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61), settings: settings, state: state), .pinned)
        state.pinned = []
        state.customIdleDays["/p/a"] = 90
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 61), settings: settings, state: state), .active(daysLeft: 29))
        state.customIdleDays = [:]
        state.kept["/p/a"] = Date().addingTimeInterval(-86_400)
        XCTAssertEqual(Planner.status(of: project("/p/a", idle: 300), settings: settings, state: state), .active(daysLeft: 59))
    }

    func testNothingIsPlannedWhileAutomaticIsOff() {
        let plan = Planner.plan(projects: [project("/p/a", idle: 500)], settings: SweepSettings(), state: SweepState())
        XCTAssertEqual(plan, Plan())
    }

    func testWarnThenCleanAfterTheWarningPeriod() {
        var settings = SweepSettings()
        settings.automatic = true
        var state = SweepState()
        let projects = [project("/p/idle", idle: 80), project("/p/active", idle: 3), project("/p/ask", idle: 80, tier: .ask),
                        project("/p/running", idle: 80, inUse: true)]
        let now = Date()

        var plan = Planner.plan(projects: projects, settings: settings, state: state, now: now)
        XCTAssertEqual(plan.warn, ["/p/idle"])
        XCTAssertTrue(plan.clean.isEmpty)

        state.pending["/p/idle"] = now.addingTimeInterval(3 * 86_400)
        plan = Planner.plan(projects: projects, settings: settings, state: state, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(plan, Plan(), "inside the warning period nothing happens")
        XCTAssertEqual(Planner.status(of: projects[0], settings: settings, state: state, now: now), .scheduled(state.pending["/p/idle"]!))

        plan = Planner.plan(projects: projects, settings: settings, state: state, now: now.addingTimeInterval(3 * 86_400 + 60))
        XCTAssertEqual(plan.clean, ["/p/idle"])
        XCTAssertTrue(plan.warn.isEmpty)
    }

    func testAScheduledProjectThatGetsUsedIsDropped() {
        var settings = SweepSettings()
        settings.automatic = true
        var state = SweepState()
        state.pending = ["/p/a": Date().addingTimeInterval(-60), "/p/gone": Date()]
        var plan = Planner.plan(projects: [project("/p/a", idle: 0)], settings: settings, state: state)
        XCTAssertEqual(plan.drop, ["/p/a", "/p/gone"])
        XCTAssertTrue(plan.clean.isEmpty)

        plan = Planner.plan(projects: [project("/p/a", idle: 90, inUse: true)], settings: settings, state: state)
        XCTAssertTrue(plan.clean.isEmpty, "a project with a running program is never cleaned")

        state.pinned = ["/p/a"]
        plan = Planner.plan(projects: [project("/p/a", idle: 90)], settings: settings, state: state)
        XCTAssertTrue(plan.clean.isEmpty)

        settings.automatic = false
        XCTAssertEqual(Planner.plan(projects: [project("/p/a", idle: 90)], settings: settings, state: state).drop, ["/p/a", "/p/gone"])
    }

    func testNoWarningCleansAtOnce() {
        var settings = SweepSettings()
        settings.automatic = true
        settings.warnDays = 0
        let plan = Planner.plan(projects: [project("/p/a", idle: 61)], settings: settings, state: SweepState())
        XCTAssertEqual(plan.clean, ["/p/a"])
    }

    // MARK: - Store

    func testStoreRoundTripAndOlderFiles() throws {
        let store = Store(directory: URL(fileURLWithPath: root + "/store"))
        XCTAssertTrue(store.isNew)
        XCTAssertFalse(store.settings.automatic)

        var settings = store.settings
        settings.automatic = true
        settings.idleDays = 90
        settings.roots = ["/a", "/b"]
        settings.kinds = [.build]
        store.settings = settings
        XCTAssertFalse(store.isNew)
        XCTAssertEqual(store.settings, settings)

        var state = SweepState()
        state.pinned = ["/a/x"]
        state.pending = ["/a/y": Date(timeIntervalSince1970: 1_800_000_000)]
        store.state = state
        XCTAssertEqual(store.state, state)

        let entry = HistoryEntry(date: Date(timeIntervalSince1970: 1_800_000_000), projectPath: "/a/x", projectName: "x",
                                 items: [.init(relativePath: "node_modules", bytes: 5, restore: "npm install")], removal: .delete, automatic: false)
        store.history = [entry]
        XCTAssertEqual(store.history, [entry])

        // A file from a version that knew fewer settings keeps its values and gets defaults for the rest.
        try #"{"automatic": true, "idleDays": 30}"#.write(toFile: root + "/store/settings.json", atomically: true, encoding: .utf8)
        let loaded = store.settings
        XCTAssertTrue(loaded.automatic)
        XCTAssertEqual(loaded.idleDays, 30)
        XCTAssertEqual(loaded.warnDays, 3)
        XCTAssertEqual(loaded.kinds, [.dependencies, .build, .cache])

        // A damaged file falls back to the safe defaults.
        try "not json".write(toFile: root + "/store/settings.json", atomically: true, encoding: .utf8)
        XCTAssertFalse(store.settings.automatic)
    }

    func testFormatting() {
        XCTAssertEqual(Format.bytes(0), "0 MB")
        XCTAssertEqual(Format.bytes(500_000), "< 1 MB")
        XCTAssertEqual(Format.bytes(736_000_000), "736 MB")
        XCTAssertEqual(Format.bytes(6_240_000_000), "6.2 GB")
        XCTAssertEqual(Format.bytes(120_000_000_000), "120 GB")
        let now = Date()
        XCTAssertEqual(Format.ago(now, now: now), "today")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3 days ago")
        XCTAssertEqual(Format.ago(now.addingTimeInterval(-74 * 86_400), now: now), "2 months ago")
        XCTAssertEqual(Format.tilde("/Users/me/code/x", home: "/Users/me"), "~/code/x")
        XCTAssertEqual(Format.tilde("/Users/meh/x", home: "/Users/me"), "/Users/meh/x")
    }

    func testEveryRuleIsUsable() {
        var names = Set<String>()
        for ecosystem in Rules.ecosystems {
            XCTAssertTrue(names.insert(ecosystem.name).inserted, "duplicate ecosystem \(ecosystem.name)")
            XCTAssertFalse(ecosystem.markers.isEmpty)
            for rule in ecosystem.artifacts {
                XCTAssertFalse(rule.name.contains("/"))
                XCTAssertFalse([".git", ".", "..", "src", ""].contains(rule.name))
                XCTAssertNotEqual(rule.tier, .never)
            }
        }
    }
}
