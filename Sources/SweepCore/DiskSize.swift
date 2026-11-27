import Foundation

public enum DiskSize {
    /// Raised when `of` starts counting differently, so sizes cached by an earlier version are measured again.
    public static let method = 2

    /// Space that comes back when a folder is deleted, in bytes. Symlinks aren't followed.
    ///
    /// Data that something outside the folder also holds is left out, because deleting the folder
    /// doesn't free it: a file with another hard link elsewhere, and an APFS clone of a file
    /// elsewhere. pnpm and Bun fill `node_modules` with clones or hard links of their store, so
    /// such a folder counts for little while the store still has the packages. Files that share
    /// their data inside the folder are counted once.
    ///
    /// Two folders that share data only with each other each count as if the other stays, so
    /// together they can free more than their sizes add up to.
    public static func of(_ path: String) -> Int64 {
        guard let pointer = strdup(path) else { return 0 }
        defer { free(pointer) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pointer, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(stream) }
        var total: Int64 = 0
        var links: [UInt64: Shared] = [:]     // by inode: a file with several names
        var clones: [UInt64: Shared] = [:]    // by clone ID: files that are full copies of each other
        var reader = SharingReader()
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_D || info == FTS_SL || info == FTS_DEFAULT,
                  let stat = entry.pointee.fts_statp?.pointee else { continue }
            let bytes = Int64(stat.st_blocks) * 512
            guard info == FTS_F, bytes > 0 else { total += bytes; continue }
            if stat.st_nlink > 1 {
                links[UInt64(stat.st_ino), default: Shared(holders: UInt32(stat.st_nlink), bytes: bytes)].seen += 1
                continue
            }
            switch reader.read(entry.pointee.fts_path) {
            case .none: total += bytes
            case .partly(let own): total += min(bytes, max(0, own))
            case .clone(let id, let copies): clones[id, default: Shared(holders: copies, bytes: bytes)].seen += 1
            }
        }
        for shared in links.values where shared.seen >= shared.holders { total += shared.bytes }
        for shared in clones.values where shared.seen >= shared.holders { total += shared.bytes }
        return total
    }

    /// Data with several holders (names of one file, or copies of one clone): how many exist, and
    /// how many of them the folder being measured contains.
    private struct Shared {
        let holders: UInt32
        let bytes: Int64
        var seen: UInt32 = 0
    }

    /// How a file shares its data with other files, as APFS reports it.
    private enum Sharing {
        /// Shares nothing. Also the answer on a disk or macOS version that doesn't report sharing.
        case none
        /// One of `copies` files that are full copies of each other, itself included.
        case clone(id: UInt64, copies: UInt32)
        /// Shares some of its data with another file; `own` bytes are this file's alone.
        case partly(own: Int64)
    }

    /// Asks APFS how a file shares its data, with one reply buffer for a whole walk.
    private struct SharingReader {
        // A reply is its length (4 bytes), which attributes came back (five groups of 4 bytes, the
        // last being the ones asked for here), then the values in the order of their bits.
        private var reply = [UInt8](repeating: 0, count: 64)
        private let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS)

        private mutating func ask(_ path: UnsafePointer<CChar>, for wanted: Int32) -> Bool {
            var request = attrlist()
            request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            request.forkattr = attrgroup_t(wanted)
            guard getattrlist(path, &request, &reply, reply.count, options) == 0 else { return false }
            let returned = reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
            return returned & UInt32(wanted) == UInt32(wanted)
        }

        mutating func read(_ path: UnsafePointer<CChar>?) -> Sharing {
            guard let path, ask(path, for: ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT) else { return .none }
            let (id, flags, copies) = reply.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self))
            }
            guard flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 else { return .none }
            if copies > 1 { return .clone(id: id, copies: copies) }
            // The private size takes APFS longer to work out, so it is asked only for these few files.
            guard ask(path, for: ATTR_CMNEXT_PRIVATESIZE) else { return .none }
            return .partly(own: reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int64.self) })
        }
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
