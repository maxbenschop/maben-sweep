import AppKit
import SwiftUI
import SweepCore

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        #if DEBUG
        Snapshot.runIfRequested()   // exits; never starts the real app
        SelfTest.runIfRequested()   // exits
        if !CommandLine.arguments.contains("--demo") { Instance.ensureSingle() }
        #else
        Instance.ensureSingle()     // may exit: the running copy shows its window instead
        #endif
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(open: { MainWindowController.shared.show($0) })
                .environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image(dot: model.nextCleanup != nil))
                .accessibilityLabel("Maben Sweep")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Notifier.setUp()
            DistributedNotificationCenter.default().addObserver(forName: .init("gg.maben.sweep.show"), object: nil, queue: .main) { _ in
                Task { @MainActor in MainWindowController.shared.show() }
            }
            guard FirstRun.checkLocation() else { return }
            AppModel.shared.start()
            // Opened by hand: show the window. Started at login: stay in the menu bar.
            if !FirstRun.launchedAtLogin, !CommandLine.arguments.contains("--no-window") { MainWindowController.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindowController.shared.show() }
        return false
    }
}

@MainActor
enum FirstRun {
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opened straight from Downloads or a disk image, macOS runs the app from a temporary
    /// read-only copy, and "Open at login" would point at a path that disappears. Ask to move it.
    /// Returns false when the user chose to quit.
    static func checkLocation() -> Bool {
        let path = Bundle.main.bundlePath
        guard isBundled, AppModel.shared.live else { return true }
        let translocated = path.contains("/AppTranslocation/")
        let inDownloads = [".Trash", "Downloads", "Desktop"].contains { path.contains("/\($0)/") }
        guard translocated || inDownloads else { return true }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Maben Sweep to Applications first"
        alert.informativeText = "Maben Sweep starts at login by its location. Drag it to your Applications folder, then open it from there."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Continue Anyway")
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil); return false }
        NSApp.setActivationPolicy(.accessory)
        return true
    }
}
