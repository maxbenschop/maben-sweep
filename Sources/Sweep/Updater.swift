import AppKit
import Combine
import Security
import SweepCore

/// Updates from GitHub Releases (github.com/maxbenschop/maben-sweep), the same way Maben Awake does.
///
/// 1. Check: ask the GitHub API for the latest release (drafts and pre-releases are never "latest").
///    Its tag `vX.Y.Z` is the version and its text the release notes. At start, every 6 hours, after
///    waking if the last check is over 6 hours old, and when you press Check now. This is the only
///    network request the app makes.
/// 2. Download `Maben-Sweep.zip` from that release to a temporary folder.
///    Only a file from this repository's releases on github.com is accepted.
/// 3. Verify before touching anything: the app inside must be signed with the Developer ID of team
///    NJTYRVLSA8 with this bundle ID, notarized by Apple (Gatekeeper accepts it), and the announced version.
/// 4. Install: the new app is copied next to the installed one and verified again there, then the
///    two are swapped by renaming, so the installed app is never missing. The old one goes to the
///    Trash, and the app restarts. In a folder only an administrator can write, the same steps
///    run as root after a password prompt (`UpdateInstall.rootCommand`).
///
/// Automatic installs wait until no scan or cleanup is running.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    typealias Release = ReleaseFeed.Release

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "updates.autoCheck"); schedule() } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "updates.autoInstall") } }

    nonisolated static let teamID = "NJTYRVLSA8"
    nonisolated static let bundleID = "gg.maben.sweep"

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastCheck: Date?
    private var wakeObserver: NSObjectProtocol?
    private var downloadObservation: NSKeyValueObservation?

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r): r
        default: nil
        }
    }

    /// Updates only install over a copy in an Applications folder (not a dev build or a translocated download).
    var canInstall: Bool {
        let path = Bundle.main.bundlePath
        return isBundled && !path.contains("/AppTranslocation/")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    private init() {
        // On by default, as in Maben Awake.
        autoCheck = defaults.object(forKey: "updates.autoCheck") as? Bool ?? true
        autoInstall = defaults.object(forKey: "updates.autoInstall") as? Bool ?? true
    }

    /// Call once at launch. Does nothing for a copy that isn't a real app (`swift run`, tests, demo).
    func start() {
        guard isBundled, AppModel.shared.live else { return }
        // What an update that was interrupted left next to the app.
        if canInstall { UpdateInstall.removeLeftovers(nextTo: Bundle.main.bundleURL) }
        schedule()
        if autoCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    private func checkAfterWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoCheck else { return }
            if let lastCheck = self.lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
            self.check(userInitiated: false)
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard autoCheck else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: ReleaseFeed.url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MabenSweep/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { ReleaseFeed.parse($0) }
            Task { @MainActor in
                if let error {
                    self.fail(userInitiated ? "Couldn't reach GitHub: \(error.localizedDescription)" : nil)
                } else if status != 200 || release == nil {
                    self.fail(userInitiated ? "GitHub didn't return a release (HTTP \(status))." : nil)
                } else if let release, ReleaseFeed.isNewer(release.version, than: self.currentVersion) {
                    self.lastCheck = Date()
                    self.state = .available(release)
                    if self.autoInstall { self.installWhenQuiet() }
                } else {
                    self.lastCheck = Date()
                    self.state = .upToDate(checked: Date())
                }
            }
        }.resume()
    }

    private func fail(_ message: String?) {
        state = message.map { .failed($0) } ?? .idle
    }

    // MARK: Install

    /// Automatic install: wait until no scan or cleanup is running.
    private func installWhenQuiet() {
        guard canInstall else { return }
        let model = AppModel.shared
        if !model.scanning && model.busy.isEmpty {
            install()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, case .available = self.state, self.autoInstall else { return }
                self.installWhenQuiet()
            }
        }
    }

    func install() {
        guard let release = available, canInstall else { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .downloading(release, progress: 0)
        let task = URLSession.shared.downloadTask(with: release.zip) { location, response, error in
            // The temporary file is deleted when this returns, so move it first.
            var kept: URL?
            if let location {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MabenSweep-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { kept = dest }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let kept, error == nil, status == 200 else {
                    self.state = .failed("The download failed\(error.map { ": \($0.localizedDescription)" } ?? " (HTTP \(status)).")")
                    return
                }
                self.state = .installing(release)
                Task.detached { await self.finish(zip: kept, release: release) }
            }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading(let r, _) = self.state { self.state = .downloading(r, progress: value) }
            }
        }
        task.resume()
    }

    /// Unpacks, verifies and swaps the app. Runs off the main thread.
    private nonisolated func finish(zip: URL, release: Release) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MabenSweepUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: zip) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw Failure("Couldn't unpack the update.") }
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw Failure("The update doesn't contain an app.") }
            try Self.verify(newApp, expectedVersion: release.version)
            let target = await MainActor.run { Bundle.main.bundleURL }
            try Self.replace(target, with: newApp, version: release.version)
            try? fm.removeItem(at: work)
            await MainActor.run { self.relaunch() }
        } catch {
            try? fm.removeItem(at: work)
            let message = (error as? Failure)?.message ?? (error as? UpdateInstall.Failure)?.message ?? error.localizedDescription
            await MainActor.run { self.state = .failed(message) }
        }
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// The downloaded app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The update isn't a valid app.")
        }
        let text = UpdateInstall.requirement(teamID: teamID, bundleID: bundleID)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("Couldn't check the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The update isn't signed by Maben and notarized by Apple. It was not installed.")
        }
        // Gatekeeper's own answer as well: it also knows what Apple has revoked.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Swaps the app bundle. `newApp` has passed `verify` already, so a bad download never gets as
    /// far as a password prompt; the copy that is put in place is verified once more where it stands.
    nonisolated static func replace(_ target: URL, with newApp: URL, version: String) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path) {
            try UpdateInstall.swap(target, with: newApp, verify: { try verify($0, expectedVersion: version) })
        } else {
            // Installed by an administrator: ask for the password once. Root copies, checks and
            // swaps (`UpdateInstall.rootCommand`).
            let command = UpdateInstall.rootCommand(newApp: newApp.path, target: target.path,
                                                    requirement: UpdateInstall.requirement(teamID: teamID, bundleID: bundleID),
                                                    version: version, token: UUID().uuidString)
            let script = UpdateInstall.appleScript(running: command, prompt: "Maben Sweep wants to install an update.")
            let p = Process(), errors = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errors
            do { try p.run() } catch { throw Failure("The update was not installed: the password prompt couldn't be shown.") }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                // osascript always says why it failed; -128 is Cancel in the password dialog.
                let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                throw Failure(message.contains("(-128)") ? "The update was not installed (no administrator password)."
                              : "The update was not installed: it couldn't be copied or didn't pass the checks.")
            }
        }
    }

    /// Opens the new version a second after this one quits.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        exit(0)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
