import Foundation

public enum DiskSize {
    /// Space a folder takes on disk, in bytes. Symlinks aren't followed, and a file with several
    /// hard links (pnpm) is counted once.
    public static func of(_ path: String) -> Int64 {
        guard let pointer = strdup(path) else { return 0 }
        defer { free(pointer) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pointer, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(stream) }
        var total: Int64 = 0
        var linked = Set<UInt64>()
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_D || info == FTS_SL || info == FTS_DEFAULT,
                  let stat = entry.pointee.fts_statp?.pointee else { continue }
            if info == FTS_F, stat.st_nlink > 1, !linked.insert(UInt64(stat.st_ino)).inserted { continue }
            total += Int64(stat.st_blocks) * 512
        }
        return total
    }

    /// Free space on the disk that holds `path`, as the Finder reports it.
    public static func available(at path: String = NSHomeDirectory()) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

public enum Format {
    public static func bytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "< 1 MB"
    }

    public static func days(since date: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    /// "today", "3 days ago", "5 weeks ago", "4 months ago", "2 years ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let d = days(since: date, now: now)
        switch d {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(d) days ago"
        case 14..<60: return "\(d / 7) weeks ago"
        case 60..<730: return "\(d / 30) months ago"
        default: return "\(d / 365) years ago"
        }
    }

    /// `~/Documents/site` instead of `/Users/name/Documents/site`.
    public static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
