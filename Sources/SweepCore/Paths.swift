import Foundation

/// One way to write and compare folder paths, so a folder is always recognised as itself: by the
/// "in use" check, by "Never look in", and when a project is looked up again before cleaning.
public enum Paths {
    /// The path as the disk has it: `~` expanded, symlinks resolved, and every name spelled the way
    /// the folder really is (`~/code` becomes `~/Code` on a disk that ignores case). This is also
    /// how macOS reports the working folder of a running program. The part of a path that doesn't
    /// exist is kept as written.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var missing: [String] = []
        var current = expanded
        while true {
            if let real = realpath(current, nil) {
                defer { free(real) }
                return missing.reversed().reduce(String(cString: real)) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else {
                return URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
            missing.append((current as NSString).lastPathComponent)
            current = parent
        }
    }

    /// False on a disk that treats `Code` and `code` as one name, as a Mac's own disk does.
    /// When the disk can't be asked, the answer is false: comparing loosely makes more folders
    /// count as in use or excluded, which is the safe side.
    public static func isCaseSensitive(at path: String) -> Bool {
        var current = path
        while true {
            let answer = pathconf(current, _PC_CASE_SENSITIVE)
            if answer >= 0 { return answer == 1 }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { return false }
            current = parent
        }
    }

    /// A path with the differences a case-ignoring disk doesn't see taken out.
    static func fold(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: nil)
    }

    public static func same(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? a == b : fold(a) == fold(b)
    }

    /// The two paths name the same folder on the disk that holds the first one.
    public static func same(_ a: String, _ b: String) -> Bool {
        same(a, b, caseSensitive: isCaseSensitive(at: a))
    }

    /// `path` is `folder` or lies below it.
    public static func isInside(_ path: String, _ folder: String, caseSensitive: Bool) -> Bool {
        if caseSensitive { return path == folder || path.hasPrefix(folder + "/") }
        let p = fold(path), f = fold(folder)
        return p == f || p.hasPrefix(f + "/")
    }

    public static func isInside(_ path: String, _ folder: String) -> Bool {
        isInside(path, folder, caseSensitive: isCaseSensitive(at: folder))
    }

    /// The paths as the disk has them, each folder once, in the order given.
    public static func canonical(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in paths.map({ canonical($0) }) where !result.contains(where: { same($0, path) }) {
            result.append(path)
        }
        return result
    }
}

/// Some folders, answering "is this one of them?" the way the disk would.
struct FolderSet: Sendable {
    private var exact: Set<String> = []
    /// The ones on a disk that ignores case, folded.
    private var folded: Set<String> = []

    init(_ paths: some Sequence<String>) {
        for path in paths {
            exact.insert(path)
            if !Paths.isCaseSensitive(at: path) { folded.insert(Paths.fold(path)) }
        }
    }

    func contains(_ path: String) -> Bool {
        exact.contains(path) || (!folded.isEmpty && folded.contains(Paths.fold(path)))
    }
}
