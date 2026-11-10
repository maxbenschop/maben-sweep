#if DEBUG
import AppKit
import SweepCore

/// `Sweep --selftest <empty folder>` (debug builds only): builds throwaway git projects in that
/// folder and drives the app's own model through a scan, the warning, an automatic cleanup and
/// the settings, with its data in that folder too. Nothing outside the folder is read or changed.
@MainActor
enum SelfTest {
    static var failures = 0

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let base = URL(fileURLWithPath: args[i + 1]).resolvingSymlinksInPath().path
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: base))?.isEmpty ?? true else {
            print("The self-test needs an empty folder."); exit(2)
        }
        _ = NSApplication.shared
        setvbuf(stdout, nil, _IONBF, 0)
        let projects = base + "/projects"
        guard let git = Git.find() else { print("git not found"); exit(2) }

        func write(_ path: String, _ text: String = "x") {
            let full = projects + "/" + path
            try! fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        func sh(_ arguments: [String], in dir: String, days: Double) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git.binary)
            p.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", projects + "/" + dir] + arguments
            let stamp = "\(Int(Date().timeIntervalSince1970 - days * 86_400)) +0000"
            p.environment = ProcessInfo.processInfo.environment.merging(["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp]) { _, new in new }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try! p.run(); p.waitUntilExit()
        }
        /// A Node project last touched `days` ago.
        func node(_ name: String, days: Double, lockfile: Bool = true) {
            write(name + "/package.json", "{}")
            if lockfile { write(name + "/package-lock.json", "{}") }
            write(name + "/src/index.js", "console.log(1)")
            write(name + "/.env", "SECRET=1")
            write(name + "/node_modules/pkg/index.js", String(repeating: "a", count: 300_000))
            write(name + "/.next/cache/data", String(repeating: "b", count: 300_000))
            write(name + "/.gitignore", "node_modules/\n.next/\n.env\n")
            sh(["init", "-q"], in: name, days: days)
            sh(["add", "-A"], in: name, days: days)
            sh(["commit", "-q", "-m", "first"], in: name, days: days)
            let date = Date().addingTimeInterval(-days * 86_400)
            var paths = [projects + "/" + name]
            for case let p as String in fm.enumerator(atPath: projects + "/" + name)! { paths.append(projects + "/" + name + "/" + p) }
            for path in paths { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: path) }
        }

        node("old-site", days: 100)
        node("older-site", days: 400)
        node("fresh-site", days: 2)
        node("no-lock", days: 200, lockfile: false)

        let store = Store(directory: URL(fileURLWithPath: base + "/store"))
        var settings = SweepSettings()
        settings.roots = [projects]
        store.settings = settings
        let model = AppModel(store: store)

        func wait(_ what: String, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !done() { check(false, "timed out: \(what)") }
        }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: projects + "/" + path) }
        func named(_ name: String) -> Project? { model.projects.first { $0.name == name } }

        // 1. A new install: automatic is off, the scan finds everything and removes nothing.
        check(!model.settings.automatic, "automatic cleanup starts off")
        check(!model.hasScanned, "not scanned yet")
        model.scan(thenApply: true)
        wait("first scan") { !model.scanning }
        check(model.projects.count == 4, "finds 4 projects (found \(model.projects.count))")
        check(model.dueProjects.map(\.name).sorted() == ["no-lock", "old-site", "older-site"], "three projects are idle: \(model.dueProjects.map(\.name))")
        check(model.status(of: named("fresh-site")!) == .active(daysLeft: 58), "the fresh project is active")
        check(named("no-lock")?.artifacts.first { $0.name == "node_modules" }?.tier == .ask, "no lockfile asks first")
        check(model.state.pending.isEmpty, "nothing is scheduled while automatic is off")
        check(exists("old-site/node_modules") && exists("older-site/.next"), "the scan removed nothing")
        check(store.projects.count == 4 && store.state.lastScan != nil, "the scan is saved")

        // 2. Turning automatic on: a warning first, nothing removed yet.
        model.settings.automatic = true
        model.applyPlan()
        check(Set(model.state.pending.keys) == [projects + "/old-site", projects + "/older-site", projects + "/no-lock"], "idle projects get a date")
        check(model.nextCleanup.map { $0.timeIntervalSinceNow > 2.9 * 86_400 } ?? false, "the cleanup is 3 days away")
        check(exists("old-site/node_modules"), "nothing removed during the warning period")
        if case .scheduled = model.status(of: named("old-site")!) {} else { check(false, "old-site shows as scheduled") }
        check(store.settings.automatic && store.state.pending.count == 3, "settings and schedule are saved")

        // 3. Working on a project during the warning period cancels its cleanup.
        write("old-site/src/index.js", "console.log(2)")
        model.scan(thenApply: true)
        wait("second scan") { !model.scanning }
        check(model.state.pending[projects + "/old-site"] == nil, "a project that was used is taken off the schedule")
        check(model.state.pending[projects + "/older-site"] != nil, "the other one stays scheduled")

        // 4. The warning period is over: the idle project is cleaned, the rest is untouched.
        model.state.pending[projects + "/no-lock"] = nil
        model.state.kept[projects + "/no-lock"] = Date()
        model.state.pending[projects + "/older-site"] = Date().addingTimeInterval(-60)
        // On battery the half-hourly check does nothing while "Only while on power" is on.
        if !Power.onAC {
            model.tick()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            check(exists("older-site/node_modules") && model.busy.isEmpty, "on battery nothing is cleaned")
        }
        model.settings.onlyOnPower = false
        model.tick()
        wait("automatic cleanup") { !model.history.isEmpty && model.busy.isEmpty }
        check(!exists("older-site/node_modules") && !exists("older-site/.next"), "the idle project's folders are gone")
        for kept in ["older-site/package.json", "older-site/package-lock.json", "older-site/src/index.js", "older-site/.env", "older-site/.git/HEAD",
                     "old-site/node_modules/pkg/index.js", "fresh-site/node_modules/pkg/index.js", "no-lock/node_modules/pkg/index.js"] {
            check(exists(kept), "kept \(kept)")
        }
        check(git.run(["status", "--porcelain"], in: projects + "/older-site").output.isEmpty, "git sees no change in the cleaned project")
        check(model.history.count == 1 && model.history.first?.automatic == true && model.history.first?.items.count == 2, "one automatic cleanup in the history")
        check(model.history.first?.restoreCommands == ["cd '\(projects)/older-site' && npm install"], "the restore command is kept")
        check(model.totalFreed > 500_000, "freed space is counted (\(model.totalFreed) bytes)")
        check(named("older-site") == nil, "a cleaned project leaves the list")
        check(model.state.pending.isEmpty, "the schedule is empty again")
        check(store.history.count == 1, "the history is saved")

        // 5. By hand: a folder that asks first is only removed on its own Remove button.
        model.state.kept = [:]
        let noLock = named("no-lock")!
        model.clean(noLock)
        wait("manual clean") { model.busy.isEmpty && !exists("no-lock/.next") }
        check(exists("no-lock/node_modules") && !exists("no-lock/.next"), "Clean leaves the folder that asks first")
        model.clean(named("no-lock")!, artifacts: named("no-lock")!.askArtifacts, allowAsk: true)
        wait("remove asked folder") { model.busy.isEmpty && !exists("no-lock/node_modules") }
        check(!exists("no-lock/node_modules"), "Remove takes the folder that asks first")
        check(model.history.count == 3 && model.history.first?.automatic == false, "both show in the history as done by hand")

        // 6. Keep, never clean, and a project's own idle time.
        model.settings.automatic = false
        check(model.state.pending.isEmpty, "turning automatic off clears the schedule")
        write("fresh-site/x")   // nothing to do with idleness; just keeps the fixture honest
        node("ancient", days: 500)
        model.scan()
        wait("third scan") { !model.scanning }
        let ancient = named("ancient")!
        check(Planner.isDue(ancient, settings: model.settings, state: model.state), "a 500-day-old project is idle")
        model.keep(ancient)
        check(model.status(of: ancient) == .active(daysLeft: 60), "Keep for now gives it a full idle period")
        model.state.kept = [:]
        model.setPinned(ancient, true)
        check(model.status(of: ancient) == .pinned && model.dueProjects.isEmpty, "a pinned project is never due")
        model.setPinned(ancient, false)
        model.setIdleDays(ancient, 365)
        check(Planner.isDue(ancient, settings: model.settings, state: model.state), "365 days: still idle at 500")
        model.settings.kinds = []
        check(model.dueProjects.isEmpty, "with every kind switched off nothing is due")
        model.settings.kinds = [.build]
        model.cleanAllDue()
        wait("clean build output only") { model.busy.isEmpty && !exists("ancient/.next") }
        check(exists("ancient/node_modules") && !exists("ancient/.next"), "only the kinds switched on are removed")

        // 7. Moving to the Trash.
        model.settings.kinds = [.dependencies, .build, .cache]
        model.settings.removal = .trash
        let before = Set((try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) ?? [])
        model.clean(named("ancient")!)
        wait("trash") { model.busy.isEmpty && !exists("ancient/node_modules") }
        check(!exists("ancient/node_modules") && model.history.first?.removal == .trash, "the Trash setting is used")
        let trashed = Set((try? fm.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash")) ?? []).subtracting(before)
        for name in trashed where name.hasPrefix("node_modules") { try? fm.removeItem(atPath: NSHomeDirectory() + "/.Trash/" + name) }

        // 8. Folders.
        model.addExcluded(projects + "/fresh-site")
        check(named("fresh-site") == nil, "an excluded folder leaves the list")
        model.removeRoot(projects)
        check(model.projects.isEmpty && model.settings.roots.isEmpty, "removing the folder empties the list")
        check(Store(directory: store.directory).settings.excluded == [projects + "/fresh-site"], "folder settings are saved")

        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "  ok    " : "  FAIL  ") + what)
        if !ok { failures += 1 }
    }
}
#endif
