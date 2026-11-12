import AppKit
import SwiftUI
import SweepCore

/// Everything the menu and the window show, and every action they can take.
@MainActor
final class AppModel: ObservableObject {
    static let shared: AppModel = {
        #if DEBUG
        if CommandLine.arguments.contains("--demo") { return Demo.model() }
        #endif
        return AppModel(store: .standard)
    }()

    let store: Store?
    /// False for demo data: nothing is read from or written to disk.
    var live: Bool { store != nil }

    @Published var settings: SweepSettings {
        didSet {
            guard settings != oldValue else { return }
            store?.settings = settings
            // Turning automatic cleanup on only makes sense if Sweep is running.
            if settings.automatic, !oldValue.automatic, live {
                if !launchAtLogin { launchAtLogin = true }
                Notifier.requestPermission()
            }
            if !settings.automatic, oldValue.automatic { state.pending = [:] }
        }
    }
    @Published var state: SweepState { didSet { if state != oldValue { store?.state = state } } }
    @Published var projects: [Project]
    @Published var history: [HistoryEntry] { didSet { store?.history = history } }
    @Published var caches: [GlobalCache] = []
    @Published var cachesLoading = false
    @Published var scanning = false
    @Published var scanningPath: String?
    /// Paths of projects and caches being cleaned right now.
    @Published var busy: Set<String> = []
    @Published var notice: String?
    @Published var freeSpace: Int64?
    /// Notifications are switched off in System Settings, so the warning before a cleanup can't be shown.
    @Published var notificationsDenied = false
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, live else { return }
            if !LoginItem.set(launchAtLogin) { launchAtLogin = LoginItem.isOn }
        }
    }

    private var timer: Timer?
    private var sizes: ProjectScanner.SizeCache = [:]

    init(store: Store) {
        self.store = store
        let isNew = store.isNew
        var settings = store.settings
        if isNew {
            settings.roots = SweepSettings.defaultRoots()
            store.settings = settings
        }
        self.settings = settings
        state = store.state
        projects = store.projects
        history = store.history
        sizes = store.sizes
        launchAtLogin = LoginItem.isOn
        freeSpace = DiskSize.available()
    }

    /// Demo data for screenshots and trying the window out.
    init(demo projects: [Project], settings: SweepSettings, state: SweepState, history: [HistoryEntry], caches: [GlobalCache]) {
        store = nil
        self.settings = settings
        self.state = state
        self.projects = projects
        self.history = history
        self.caches = caches
        launchAtLogin = settings.automatic
        freeSpace = 41_300_000_000
    }

    // MARK: - What the views show

    func status(of project: Project) -> ProjectStatus {
        Planner.status(of: project, settings: settings, state: state)
    }

    /// Idle projects with something automatic cleanup may remove.
    var dueProjects: [Project] {
        projects.filter { Planner.isDue($0, settings: settings, state: state) }
            .sorted { $0.safeBytes(kinds: settings.kinds) > $1.safeBytes(kinds: settings.kinds) }
    }

    var dueBytes: Int64 { dueProjects.reduce(0) { $0 + $1.safeBytes(kinds: settings.kinds) } }

    /// Projects with folders that are only removed on a click, for reviewing them in one go.
    /// Pinned projects and projects in use are left out; idle ones come first, biggest first.
    var askingProjects: [Project] {
        projects.filter { !$0.askArtifacts.isEmpty && !$0.inUse && !state.pinned.contains($0.path) }
            .sorted { a, b in
                let ia = isIdle(a), ib = isIdle(b)
                return ia != ib ? ia : a.askArtifacts.reduce(0) { $0 + $1.bytes } > b.askArtifacts.reduce(0) { $0 + $1.bytes }
            }
    }

    /// Unused for at least its idle period, whether or not it has anything safe in it.
    func isIdle(_ project: Project) -> Bool {
        Format.days(since: Planner.effectiveActivity(of: project, state: state))
            >= Planner.threshold(for: project, settings: settings, state: state)
    }

    /// What the review starts with ticked: folders in idle projects, except Python environments,
    /// which can hold packages installed by hand.
    func preselectedAsks(in projects: [Project]) -> Set<String> {
        Set(projects.filter(isIdle).flatMap(\.askArtifacts).filter { $0.kind != .environment }.map(\.path))
    }
    var totalFreed: Int64 { history.reduce(0) { $0 + $1.bytes } }
    var nextCleanup: Date? { settings.automatic ? state.pending.values.min() : nil }
    var hasScanned: Bool { state.lastScan != nil }

    var headline: String {
        if scanning && projects.isEmpty { return "Looking for projects…" }
        if !hasScanned { return "Ready to scan" }
        let due = dueProjects
        if due.isEmpty { return "Nothing to clean" }
        return "\(Format.bytes(dueBytes)) in \(due.count) idle \(due.count == 1 ? "project" : "projects")"
    }

    var statusText: String {
        if scanning { return "Scanning…" }
        if !hasScanned { return "Sweep hasn't looked at your projects yet." }
        if !settings.automatic { return "Automatic cleanup is off." }
        if let next = nextCleanup { return "Next cleanup \(Self.day(next))." }
        return "Cleans projects idle for \(settings.idleDays) days."
    }

    /// "today", "tomorrow", "on Friday", "on 21 November".
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if date <= now || calendar.isDate(date, inSameDayAs: now) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = days < 7 ? "EEEE" : "d MMMM"
        return "on " + formatter.string(from: date)
    }

    // MARK: - Scanning

    func scan(thenApply: Bool = false) {
        guard live, !scanning else { return }
        scanning = true
        notice = nil
        let scanner = ProjectScanner(roots: settings.roots, excluded: settings.excluded)
        let cached = sizes
        Task.detached(priority: .utility) {
            let result = scanner.scan(sizes: cached) { [weak self] path in
                Task { @MainActor in if self?.scanning == true { self?.scanningPath = path } }
            }
            await MainActor.run {
                self.projects = result.projects
                self.sizes = result.sizes
                self.store?.projects = result.projects
                self.store?.sizes = result.sizes
                self.state.lastScan = Date()
                self.scanning = false
                self.scanningPath = nil
                self.freeSpace = DiskSize.available()
                if thenApply { self.applyPlan() }
                self.checkLowDisk()
            }
        }
    }

    // MARK: - Cleaning

    /// Cleans one project on a click. `artifacts` nil means everything safe in it.
    func clean(_ project: Project, artifacts: [Artifact]? = nil, allowAsk: Bool = false) {
        clean([project], artifacts: artifacts, allowAsk: allowAsk, automatic: false)
    }

    /// Removes folders the user ticked themselves, across any number of projects. Folders that ask
    /// first are allowed; each one is still checked again right before it goes.
    func removeChosen(_ artifacts: [Artifact]) {
        let paths = Set(artifacts.map(\.path))
        let targets = projects.filter { $0.artifacts.contains { paths.contains($0.path) } }
        clean(targets, artifacts: artifacts, allowAsk: true, automatic: false)
    }

    func cleanAllDue() {
        clean(dueProjects, artifacts: nil, allowAsk: false, automatic: false)
    }

    private func clean(_ targets: [Project], artifacts: [Artifact]?, allowAsk: Bool, automatic: Bool) {
        guard live else { return }
        let targets = targets.filter { !busy.contains($0.path) }
        guard !targets.isEmpty else { return }
        busy.formUnion(targets.map(\.path))
        let settings = settings
        let state = state
        let scanner = ProjectScanner(roots: self.settings.roots, excluded: self.settings.excluded)
        Task.detached(priority: .utility) {
            var entries: [HistoryEntry] = []
            var fresh: [String: Project?] = [:]
            var problems: [String] = []
            let index = ActivityIndex.current()
            let cleaner = Cleaner(removal: settings.removal)
            for target in targets {
                // Look again right now: the list on screen can be hours old.
                guard let project = scanner.rescan(project: target.path, index: index) else {
                    fresh[target.path] = .some(nil)
                    continue
                }
                if project.inUse {
                    problems.append("\(project.name) is in use, so it was left alone.")
                    fresh[target.path] = project
                    continue
                }
                // An automatic run only goes ahead if the project is still idle at this moment.
                if automatic, !Planner.isDue(project, settings: settings, state: state) {
                    fresh[target.path] = project
                    continue
                }
                let wanted = artifacts.map { chosen in project.artifacts.filter { a in chosen.contains { $0.path == a.path } } }
                    ?? project.safeArtifacts(kinds: settings.kinds)
                let result = cleaner.clean(wanted, in: project, allowAsk: allowAsk)
                if let entry = Cleaner.entry(for: result, project: project, removal: settings.removal, automatic: automatic) {
                    entries.append(entry)
                }
                for skipped in result.skipped { problems.append("\(project.name)/\(skipped.artifact.relativePath): \(skipped.reason)") }
                fresh[target.path] = scanner.rescan(project: target.path, index: index)
            }
            let done = entries, updated = fresh, issues = problems
            await MainActor.run {
                for (path, project) in updated {
                    self.projects.removeAll { $0.path == path }
                    if let project { self.projects.append(project) }
                    self.state.pending[path] = nil
                }
                self.projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.store?.projects = self.projects
                self.history.insert(contentsOf: done.reversed(), at: 0)
                self.busy.subtract(targets.map(\.path))
                self.freeSpace = DiskSize.available()
                self.notice = issues.isEmpty ? nil : issues.prefix(3).joined(separator: "\n")
                let freed = done.reduce(0) { $0 + $1.bytes }
                if automatic, freed > 0 { Notifier.cleaned(projects: done.count, bytes: freed) }
            }
        }
    }

    // MARK: - Per project

    /// Counts as activity from now: the project gets a full idle period again.
    func keep(_ project: Project) {
        state.kept[project.path] = Date()
        state.pending[project.path] = nil
    }

    func keepAllPending() {
        let now = Date()
        for path in state.pending.keys { state.kept[path] = now }
        state.pending = [:]
    }

    func setPinned(_ project: Project, _ pinned: Bool) {
        if pinned { state.pinned.insert(project.path); state.pending[project.path] = nil } else { state.pinned.remove(project.path) }
    }

    func setIdleDays(_ project: Project, _ days: Int?) {
        state.customIdleDays[project.path] = days
        state.pending[project.path] = nil
    }

    // MARK: - Automatic

    func start() {
        guard live, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { Task { @MainActor in AppModel.shared.tick() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Task { @MainActor in AppModel.shared.tick() } }
    }

    /// Runs every half hour: scans once a day, and cleans what is due if automatic cleanup is on.
    func tick() {
        guard live, !scanning, hasScanned else { return }
        if settings.onlyOnPower, !Power.onAC { return }
        let stale = Date().timeIntervalSince(state.lastScan ?? .distantPast) > 24 * 3600
        if stale {
            scan(thenApply: true)
        } else if settings.automatic, state.pending.values.contains(where: { $0 <= Date() }) {
            applyPlan()
        }
    }

    /// Warns about newly idle projects and cleans the ones whose warning period is over.
    func applyPlan() {
        let plan = Planner.plan(projects: projects, settings: settings, state: state)
        for path in plan.drop { state.pending[path] = nil }
        guard settings.automatic else { return }
        if !plan.warn.isEmpty {
            let date = Date().addingTimeInterval(Double(settings.warnDays) * 86_400)
            for path in plan.warn { state.pending[path] = date }
            let warned = projects.filter { plan.warn.contains($0.path) }
            Notifier.warn(projects: warned.count, bytes: warned.reduce(0) { $0 + $1.safeBytes(kinds: settings.kinds) }, on: date)
        }
        let targets = projects.filter { plan.clean.contains($0.path) }
        if !targets.isEmpty { clean(targets, artifacts: nil, allowAsk: false, automatic: true) }
    }

    private func checkLowDisk() {
        guard settings.lowDiskAlert, let free = freeSpace, free < Int64(settings.lowDiskGB) * 1_000_000_000 else { return }
        guard dueBytes > 0, Date().timeIntervalSince(state.lastLowDiskAlert ?? .distantPast) > 24 * 3600 else { return }
        state.lastLowDiskAlert = Date()
        Notifier.lowDisk(free: free, reclaimable: dueBytes)
    }

    // MARK: - Caches

    func loadCaches() {
        guard live, !cachesLoading else { return }
        cachesLoading = true
        Task.detached(priority: .utility) {
            let found = GlobalCaches.present()
            await MainActor.run {
                self.caches = found
                self.cachesLoading = false
            }
        }
    }

    func empty(_ cache: GlobalCache) {
        guard live, !busy.contains(cache.path) else { return }
        busy.insert(cache.path)
        let removal = settings.removal
        Task.detached(priority: .utility) {
            GlobalCaches.empty(cache, removal: removal)
            let found = GlobalCaches.present()
            await MainActor.run {
                self.caches = found
                self.busy.remove(cache.path)
                self.freeSpace = DiskSize.available()
            }
        }
    }

    // MARK: - History

    /// Opens Terminal and runs the commands that bring a cleanup back.
    func restore(_ entry: HistoryEntry) {
        guard live else { return }
        let commands = entry.restoreCommands
        guard !commands.isEmpty else { return }
        let script = (["#!/bin/zsh -l", "echo 'Maben Sweep: restoring \(entry.projectName.replacingOccurrences(of: "'", with: ""))'"]
            + commands + ["echo", "echo 'Done. You can close this window.'"]).joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maben-sweep-restore-\(entry.id.uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            notice = "Couldn't start the restore: \(error.localizedDescription)"
        }
    }

    func clearHistory() { history = [] }

    // MARK: - Folders

    func addRoot(_ path: String) {
        guard !settings.roots.contains(path) else { return }
        settings.roots.append(path)
        scan()
    }

    func removeRoot(_ path: String) {
        settings.roots.removeAll { $0 == path }
        projects.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        store?.projects = projects
    }

    func addExcluded(_ path: String) {
        guard !settings.excluded.contains(path) else { return }
        settings.excluded.append(path)
        projects.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        store?.projects = projects
    }

    func removeExcluded(_ path: String) {
        settings.excluded.removeAll { $0 == path }
    }
}
