import Foundation

/// A cache shared by all projects, such as Xcode's DerivedData. Never cleaned automatically.
public struct GlobalCache: Identifiable, Hashable, Sendable {
    public let name: String
    public let detail: String
    public let path: String
    public var bytes: Int64 = 0
    public var id: String { path }

    public init(name: String, detail: String, path: String, bytes: Int64 = 0) {
        self.name = name
        self.detail = detail
        self.path = path
        self.bytes = bytes
    }
}

public enum GlobalCaches {
    /// Every cache Sweep knows, whether it exists on this Mac or not.
    public static func known(home: String = NSHomeDirectory()) -> [GlobalCache] {
        [
            ("Xcode DerivedData", "Rebuilt the next time you build in Xcode.", "Library/Developer/Xcode/DerivedData"),
            ("Xcode device support", "Copied again when you connect a device.", "Library/Developer/Xcode/iOS DeviceSupport"),
            ("Simulator caches", "Rebuilt when a simulator starts.", "Library/Developer/CoreSimulator/Caches"),
            ("npm cache", "Packages download again when needed.", ".npm/_cacache"),
            ("Yarn cache", "Packages download again when needed.", "Library/Caches/Yarn"),
            ("pnpm store", "Packages download again when needed.", "Library/pnpm/store"),
            ("Bun cache", "Packages download again when needed.", ".bun/install/cache"),
            ("pip cache", "Packages download again when needed.", "Library/Caches/pip"),
            ("uv cache", "Packages download again when needed.", ".cache/uv"),
            ("Homebrew downloads", "Installers Homebrew already used.", "Library/Caches/Homebrew"),
            ("CocoaPods cache", "Pods download again when needed.", "Library/Caches/CocoaPods"),
            ("Swift packages cache", "Packages download again when needed.", "Library/Caches/org.swift.swiftpm"),
            ("Cargo registry", "Crates download again when needed.", ".cargo/registry"),
            ("Gradle caches", "Dependencies download again when needed.", ".gradle/caches"),
            ("Go build cache", "Rebuilt the next time you build.", "Library/Caches/go-build"),
            ("Playwright browsers", "Download again with playwright install.", "Library/Caches/ms-playwright"),
        ].map { GlobalCache(name: $0.0, detail: $0.1, path: home + "/" + $0.2) }
    }

    /// The caches that exist, with their sizes, largest first.
    public static func present(home: String = NSHomeDirectory()) -> [GlobalCache] {
        known(home: home)
            .filter { Safety.isRealDirectory($0.path) }
            .map { cache in var c = cache; c.bytes = DiskSize.of(cache.path); return c }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Empties a cache: removes what's inside and keeps the folder. Only works for a known cache path.
    @discardableResult
    public static func empty(_ cache: GlobalCache, removal: Removal, home: String = NSHomeDirectory()) -> Int64 {
        guard known(home: home).contains(where: { $0.path == cache.path }), Safety.isRealDirectory(cache.path) else { return 0 }
        let before = DiskSize.of(cache.path)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] {
            let url = URL(fileURLWithPath: cache.path).appendingPathComponent(name)
            switch removal {
            case .trash: try? fm.trashItem(at: url, resultingItemURL: nil)
            case .delete: try? fm.removeItem(at: url)
            }
        }
        return max(0, before - DiskSize.of(cache.path))
    }
}
