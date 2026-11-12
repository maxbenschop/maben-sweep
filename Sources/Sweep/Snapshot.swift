#if DEBUG
import AppKit
import SwiftUI
import SweepCore

/// Made-up projects for screenshots and for trying the window without touching real folders.
/// `Sweep --demo` opens the app on this data; nothing is read from or written to disk.
@MainActor
enum Demo {
    static func project(_ name: String, _ ecosystems: [String], idle days: Double, _ artifacts: [(String, ArtifactKind, Double, Tier, String?, String?)],
                        git: Bool = true, inUse: Bool = false, source: ActivitySource = .commit) -> Project {
        let path = NSHomeDirectory() + "/Developer/" + name
        return Project(path: path, name: name, isGit: git, ecosystems: ecosystems,
                       artifacts: artifacts.map { a in
                           Artifact(path: path + "/" + a.0, relativePath: a.0, name: (a.0 as NSString).lastPathComponent,
                                    ecosystem: ecosystems[0], kind: a.1, tier: a.3, reason: a.4, bytes: Int64(a.2 * 1_000_000), restore: a.5)
                       },
                       lastActivity: Date().addingTimeInterval(-days * 86_400), activitySource: source, inUse: inUse)
    }

    static func model(automatic: Bool = true, scanned: Bool = true) -> AppModel {
        let projects = [
            project("webshop", ["Node"], idle: 212, [("node_modules", .dependencies, 933, .safe, nil, "pnpm install"), (".next", .build, 1620, .safe, nil, nil)]),
            project("portfolio-2024", ["Node"], idle: 148, [("node_modules", .dependencies, 736, .safe, nil, "npm install"), (".next", .build, 154, .safe, nil, nil), (".turbo", .cache, 88, .safe, nil, nil)]),
            project("invoice-api", ["Rust"], idle: 96, [("target", .build, 2840, .safe, nil, "cargo build")]),
            project("travel-app", ["Node", "CocoaPods"], idle: 74, [("ios/Pods", .dependencies, 646, .safe, nil, "pod install"), ("node_modules", .dependencies, 512, .safe, nil, "yarn install"), (".expo", .cache, 5, .safe, nil, nil)]),
            project("thesis-analysis", ["Python"], idle: 81, [(".venv", .environment, 412, .ask, "May hold packages installed by hand", "uv sync"), (".pytest_cache", .cache, 2, .safe, nil, nil)]),
            project("landing-page", ["Node"], idle: 41, [("node_modules", .dependencies, 459, .safe, nil, "npm install"), ("dist", .build, 12, .safe, nil, nil)]),
            project("dashboard", ["Node"], idle: 2, [("node_modules", .dependencies, 852, .safe, nil, "pnpm install"), (".next", .build, 340, .safe, nil, nil)], source: .agent),
            project("menu-bar-app", ["Swift"], idle: 0, [(".build", .build, 733, .safe, nil, "swift build")], inUse: true),
            project("old-prototype", ["Node"], idle: 390, [("node_modules", .dependencies, 301, .ask, "No lockfile, so a reinstall may give other versions", nil)]),
            project("bookkeeping-app", ["Node"], idle: 395, [("node_modules", .dependencies, 593, .ask, "The project isn't in git", "npm install"), (".next", .build, 59, .ask, "The project isn't in git", nil)], git: false),
            project("Catalog.Api", [".NET"], idle: 14, [("bin", .build, 41, .ask, "The project isn't in git", "dotnet build"), ("obj", .build, 30, .ask, "The project isn't in git", "dotnet build")], git: false),
            project("client-site", ["PHP"], idle: 120, [("vendor", .dependencies, 64, .safe, nil, "composer install")]),
        ]
        var settings = SweepSettings()
        settings.automatic = automatic
        settings.roots = [NSHomeDirectory() + "/Developer", NSHomeDirectory() + "/Documents"]
        var state = SweepState()
        if scanned { state.lastScan = Date() }
        if automatic {
            let friday = Date().addingTimeInterval(3 * 86_400)
            for name in ["webshop", "portfolio-2024", "invoice-api"] { state.pending[NSHomeDirectory() + "/Developer/" + name] = friday }
        }
        state.pinned = [NSHomeDirectory() + "/Developer/client-site"]
        let history = [
            HistoryEntry(date: Date().addingTimeInterval(-2 * 86_400), projectPath: NSHomeDirectory() + "/Developer/blog", projectName: "blog",
                         items: [.init(relativePath: "node_modules", bytes: 611_000_000, restore: "npm install"), .init(relativePath: ".next", bytes: 203_000_000, restore: nil)],
                         removal: .delete, automatic: true),
            HistoryEntry(date: Date().addingTimeInterval(-2 * 86_400), projectPath: NSHomeDirectory() + "/Developer/game-jam", projectName: "game-jam",
                         items: [.init(relativePath: "target", bytes: 3_120_000_000, restore: "cargo build")], removal: .delete, automatic: true),
            HistoryEntry(date: Date().addingTimeInterval(-9 * 86_400), projectPath: NSHomeDirectory() + "/Developer/course-site", projectName: "course-site",
                         items: [.init(relativePath: "node_modules", bytes: 488_000_000, restore: "pnpm install")], removal: .trash, automatic: false),
        ]
        let caches = [
            GlobalCache(name: "Xcode DerivedData", detail: "Rebuilt the next time you build in Xcode.", path: "/demo/DerivedData", bytes: 14_200_000_000),
            GlobalCache(name: "npm cache", detail: "Packages download again when needed.", path: "/demo/npm", bytes: 3_900_000_000),
            GlobalCache(name: "Homebrew downloads", detail: "Installers Homebrew already used.", path: "/demo/brew", bytes: 1_300_000_000),
            GlobalCache(name: "Cargo registry", detail: "Crates download again when needed.", path: "/demo/cargo", bytes: 870_000_000),
            GlobalCache(name: "Playwright browsers", detail: "Download again with playwright install.", path: "/demo/pw", bytes: 640_000_000),
        ]
        return AppModel(demo: scanned ? projects : [], settings: settings, state: state, history: scanned ? history : [], caches: caches)
    }
}

/// `Sweep --snapshot <dir>` (debug builds only) renders the menu and every page to PNGs with
/// demo data, without reading or changing anything on disk.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let on = Demo.model(automatic: true)
        let off = Demo.model(automatic: false)
        let fresh = Demo.model(automatic: false, scanned: false)

        render(MenuView().environmentObject(on), "menu-on", dir)
        render(MenuView().environmentObject(off), "menu-off", dir)
        render(MenuView().environmentObject(fresh), "menu-fresh", dir)

        for (model, suffix) in [(on, "on"), (off, "off"), (fresh, "fresh")] {
            ProjectsPane.initiallyExpanded = suffix == "off" ? [NSHomeDirectory() + "/Developer/travel-app", NSHomeDirectory() + "/Developer/thesis-analysis"] : []
            let controller = MainWindowController(model: model)
            guard let window = controller.window else { continue }
            window.setFrameAutosaveName("")
            window.setContentSize(NSSize(width: MainWindowController.size.width, height: suffix == "fresh" ? 600 : 1500))
            window.orderFrontRegardless()
            for pane in Pane.allCases where suffix == "on" || pane == .projects || pane == .cleanup {
                controller.navigation.pane = pane
                RunLoop.main.run(until: Date() + 0.5)
                if let view = window.contentView?.superview ?? window.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("window-\(pane.rawValue)-\(suffix).png"))
                }
            }
            window.orderOut(nil)
        }
        render(AskReview(projects: on.askingProjects, chosen: on.preselectedAsks(in: on.askingProjects)).environmentObject(on), "ask-review", dir)
        for (size, dot) in [(CGFloat(18), false), (18, true), (144, false)] {
            let image = MenuIcon.image(size: size, dot: dot)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size) * 2, pixelsHigh: Int(size) * 2, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: size * 2, height: size * 2).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: size * 2, height: size * 2))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("icon-\(Int(size))\(dot ? "-dot" : "").png"))
        }
        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + 0.3)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
#endif
