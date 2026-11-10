import Foundation

/// Settings, state, history and the size cache, as JSON files in one folder
/// (`~/Library/Application Support/Maben Sweep`).
public final class Store: @unchecked Sendable {
    public let directory: URL

    public static var standard: Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Store(directory: base.appendingPathComponent("Maben Sweep", isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Reads a value, filling in defaults for anything the file doesn't have yet, so a file
    /// written by an older version still loads after a setting is added.
    private func load<T: Codable>(_ name: String, default fallback: T) -> T {
        guard let data = try? Data(contentsOf: url(name)) else { return fallback }
        if let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let base = try? JSONSerialization.jsonObject(with: Self.encoder.encode(fallback)) as? [String: Any] {
            let merged = base.merging(stored) { _, new in new }
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let value = try? Self.decoder.decode(T.self, from: mergedData) { return value }
        }
        return (try? Self.decoder.decode(T.self, from: data)) ?? fallback
    }

    private func save<T: Codable>(_ value: T, _ name: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    /// True until settings have been saved once.
    public var isNew: Bool { !FileManager.default.fileExists(atPath: url("settings").path) }

    public var settings: SweepSettings {
        get {
            var fallback = SweepSettings()
            fallback.roots = SweepSettings.defaultRoots()
            return load("settings", default: fallback)
        }
        set { save(newValue, "settings") }
    }

    public var state: SweepState {
        get { load("state", default: SweepState()) }
        set { save(newValue, "state") }
    }

    public var history: [HistoryEntry] {
        get { (try? Self.decoder.decode([HistoryEntry].self, from: Data(contentsOf: url("history")))) ?? [] }
        set { save(newValue, "history") }
    }

    public var sizes: ProjectScanner.SizeCache {
        get { (try? Self.decoder.decode(ProjectScanner.SizeCache.self, from: Data(contentsOf: url("sizes")))) ?? [:] }
        set { save(newValue, "sizes") }
    }

    /// The last scan, so the window has something to show before the first new scan finishes.
    public var projects: [Project] {
        get { (try? Self.decoder.decode([Project].self, from: Data(contentsOf: url("projects")))) ?? [] }
        set { save(newValue, "projects") }
    }
}
