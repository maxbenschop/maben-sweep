import AppKit
import IOKit.ps
import ServiceManagement
import SweepCore
import UserNotifications

/// True when the app runs from a real .app bundle (not a bare binary in a terminal).
let isBundled = Bundle.main.bundleURL.pathExtension == "app"

enum Power {
    /// On the charger, or a Mac without a battery.
    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPSACPowerValue
    }
}

enum LoginItem {
    static var isOn: Bool { isBundled && SMAppService.mainApp.status == .enabled }

    /// Returns false when macOS refused.
    static func set(_ on: Bool) -> Bool {
        guard isBundled else { return false }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}

/// Only one copy runs. Opening the app again brings the running copy's window forward.
enum Instance {
    static func ensureSingle() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return }
        DistributedNotificationCenter.default().postNotificationName(.init("gg.maben.sweep.show"), object: nil, userInfo: nil, deliverImmediately: true)
        other.activate()
        exit(0)
    }
}

/// The three notifications Sweep sends: a warning before a cleanup, the result, and low disk space.
@MainActor
enum Notifier {
    private static let delegate = Delegate()

    static func setUp() {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let keep = UNNotificationAction(identifier: "keep", title: "Keep them", options: [])
        let review = UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "warn", actions: [review, keep], intentIdentifiers: [])])
    }

    /// Asked the first time it matters: when automatic cleanup is turned on.
    static func requestPermission() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// True when the user has switched Sweep's notifications off in System Settings.
    static func checkDenied(_ result: @escaping @MainActor (Bool) -> Void) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in result(denied) }
        }
    }

    static func warn(projects: Int, bytes: Int64, on date: Date) {
        send(id: "warn", category: "warn",
             title: "Sweep will clean \(projects) idle \(projects == 1 ? "project" : "projects") \(AppModel.day(date))",
             body: "Frees \(Format.bytes(bytes)). Only folders that come back with one command are removed.")
    }

    static func cleaned(projects: Int, bytes: Int64) {
        send(id: "cleaned", category: nil,
             title: "Sweep freed \(Format.bytes(bytes))",
             body: "Cleaned \(projects) idle \(projects == 1 ? "project" : "projects"). History shows how to bring them back.")
    }

    static func lowDisk(free: Int64, reclaimable: Int64) {
        send(id: "lowdisk", category: nil,
             title: "Only \(Format.bytes(free)) of disk space left",
             body: "Sweep can free \(Format.bytes(reclaimable)) from idle projects.")
    }

    private static func send(id: String, category: String?, title: String, body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let action = response.actionIdentifier
            let id = response.notification.request.identifier
            Task { @MainActor in
                if action == "keep" {
                    AppModel.shared.keepAllPending()
                } else {
                    MainWindowController.shared.show(id == "cleaned" ? .history : .projects)
                }
            }
            completionHandler()
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner])
        }
    }
}
