import Foundation

extension ArtifactRule {
    /// True when the folder shows one of the rule's signs, or the rule asks for none.
    /// - Parameters:
    ///   - folder: the folder itself
    ///   - parent: the folder it sits in, and `siblings` the names in there
    func hasEvidence(folder: String, parent: String, siblings: Set<String>) -> Bool {
        evidence.isEmpty || evidence.contains { sign in
            switch sign {
            case .contains(let patterns): patterns.contains { Evidence.exists($0, in: folder) }
            case .uses(let file, let tools): siblings.contains(file) && Evidence.lists(tools, in: parent + "/" + file)
            case .namedAsOutput: Evidence.isNamedAsOutput(name, by: siblings, in: parent)
            }
        }
    }
}

extension Evidence {
    /// Something matching `pattern` exists in `folder`. `a/b` looks one folder down, and a name
    /// may hold `*`. Only real folders are looked into, and at most 500 names in each.
    static func exists(_ pattern: String, in folder: String) -> Bool {
        matches(pattern.split(separator: "/").map(String.init)[...], in: folder)
    }

    private static func matches(_ parts: ArraySlice<String>, in folder: String) -> Bool {
        guard let part = parts.first else { return true }
        let rest = parts.dropFirst()
        func found(_ name: String) -> Bool {
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            return rest.isEmpty || (info.st_mode & S_IFMT == S_IFDIR && matches(rest, in: path))
        }
        guard part.contains("*") else { return found(part) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).prefix(500)
        return names.contains { fits(part, $0) && found($0) }
    }

    /// `name` matches `pattern`, where each `*` stands for any run of characters.
    static func fits(_ pattern: String, _ name: String) -> Bool {
        let pieces = pattern.components(separatedBy: "*")
        guard pieces.count > 1 else { return pattern == name }
        guard name.count >= pieces.reduce(0, { $0 + $1.count }), name.hasPrefix(pieces[0]), name.hasSuffix(pieces[pieces.count - 1]) else { return false }
        var rest = name.dropFirst(pieces[0].count).dropLast(pieces[pieces.count - 1].count)
        for piece in pieces.dropFirst().dropLast() {
            guard let range = rest.range(of: piece) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }

    /// The text of a small regular file. Nil for anything else: a pipe with a config file's name
    /// would otherwise hold up the scan.
    private static func text(of path: String, limit: Int = 512_000) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return String(decoding: handle.readData(ofLength: limit), as: UTF8.self)
    }

    private static func found(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The file lists one of the tools as a key, the way `package.json` lists a dependency: `"vite": "^5.0.0"`.
    static func lists(_ tools: [String], in file: String) -> Bool {
        guard let text = text(of: file) else { return false }
        return tools.contains { found("\"" + NSRegularExpression.escapedPattern(for: $0) + "\"\\s*:", in: text) }
    }

    /// Scripts and config files of JavaScript build tools.
    static func isBuildConfig(_ name: String) -> Bool {
        if ["package.json", "angular.json", "turbo.json", "project.json", "nx.json", "nest-cli.json", "ng-package.json",
            "jsconfig.json", ".swcrc", ".babelrc", "electron-builder.yml", "electron-builder.json"].contains(name) { return true }
        if name.hasPrefix("tsconfig"), name.hasSuffix(".json") { return true }
        // vite.config.ts, webpack.config.js, rollup.config.mjs, jest.config.cjs, .puppeteerrc.cjs…
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = parts.last, ["js", "cjs", "mjs", "ts", "cts", "mts", "json"].contains(String(last)) else { return false }
        return parts.count >= 3 && (parts[parts.count - 2] == "config" || parts[parts.count - 2].hasSuffix("rc"))
    }

    /// One of the build scripts or config files next to the folder names it as the place its
    /// output goes. Only clear cases count: a word like "build" is also the name of a script
    /// and of a command, so the folder has to show up as a path or behind an output option.
    static func isNamedAsOutput(_ name: String, by siblings: Set<String>, in parent: String) -> Bool {
        let n = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            // "outDir": "dist", --outDir dist, -o build, dir: 'dist', coverageDirectory: "coverage"
            #"(?i)(?<![A-Za-z])(out[-_]?dir|output[-_]?(dir|path|directory)?|dist[-_]?dir|build[-_]?dir|dest(ination|[-_]?dir)?|(cache|coverage|reports?)[-_]?(dir|directory|location)|out|dir|-o|-d)["']?\s*[:=\s]\s*["'`]?(\./)?"#
                + n + #"/?(?=["'`\s,;)\]}]|$)"#,
            // path.resolve(__dirname, 'dist')
            #"(resolve|join)\([^)\n]*["'`]"# + n + #"["'`]\s*\)"#,
            // "main": "dist/index.js"
            #"["'`](\./)?"# + n + "/",
            // "files": ["dist"]
            #""files"\s*:\s*\[[^\]]*"(\./)?"# + n + #"/?""#,
            // "clean": "rimraf dist", "rm -rf build out"
            #"(rimraf|rm -rf|rm -fr|del-cli|del)\s[^"&|;\n]*(?<![\w./-])"# + n + #"(?![\w.-])"#,
        ]
        for file in siblings.filter(isBuildConfig).sorted().prefix(40) {
            guard let text = text(of: parent + "/" + file) else { continue }
            if patterns.contains(where: { found($0, in: text) }) { return true }
        }
        return false
    }
}
