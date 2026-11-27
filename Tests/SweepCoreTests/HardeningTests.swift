import XCTest
@testable import SweepCore

/// Tests for the checks that keep Sweep from running anything a scanned folder names, and from
/// removing work that only looks like build output. They use the helpers of `SweepCoreTests`.
extension SweepCoreTests {
    // MARK: - Helpers

    /// Plain git, with nothing switched off, the way a shell would run it. Returns the exit status.
    @discardableResult
    func plainGit(_ binary: String, _ args: [String], in dir: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-C", root + "/" + dir] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// An executable script.
    @discardableResult
    func script(_ path: String, _ text: String) -> String {
        let full = write(path, text)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
        return full
    }

    // MARK: - Git: a repository can't make it run anything

    /// A repository whose own config, hooks and attributes name `tool` everywhere a program can be
    /// named. Its newest commit carries a signature.
    /// - Parameter partialClone: it also claims to be a partial clone with objects to fetch, and
    ///   has a branch whose commit is missing. git then stops before it gets to the signature,
    ///   which is why both kinds are tested.
    func hostileRepository(_ name: String, tool: String, partialClone: Bool) {
        nodeProject(name)
        write(name + "/.gitattributes", "* filter=evil diff=evil\n")
        // A commit that carries a signature, so anything that checks signatures would start
        // `gpg.program`. It is the newest commit, the one `git log -1` shows.
        let stamp = Int(Date().timeIntervalSince1970) + 3600
        let body = "tree \(output(["rev-parse", "HEAD^{tree}"], in: name))\nparent \(output(["rev-parse", "HEAD"], in: name))\n"
            + "author T <t@example.com> \(stamp) +0000\n"
            + "committer T <t@example.com> \(stamp) +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n\nsigned\n"
        let file = write(name + "-commit.txt", body)
        let signed = output(["hash-object", "-t", "commit", "-w", file], in: name)
        sh(["update-ref", "refs/heads/signed", signed], in: name)

        for hook in ["fsmonitor-watchman", "post-index-change", "reference-transaction", "pre-auto-gc", "post-checkout"] {
            script(name + "/.git/hooks/" + hook, "#!/bin/sh\n\(tool)\n")
            script(name + "/hooks/" + hook, "#!/bin/sh\n\(tool)\n")
        }
        // More of the same in a file the config includes.
        write(name + "-included.cfg", "[core]\n\tfsmonitor = \(tool)\n\tpager = \(tool)\n[pager]\n\tls-files = \(tool)\n\trev-list = \(tool)\n")
        var settings = [
            "include.path": root + "/" + name + "-included.cfg",
            "core.hooksPath": root + "/" + name + "/hooks",
            "core.fsmonitor": tool, "core.sshCommand": tool, "core.editor": tool, "core.askPass": tool, "core.gitProxy": tool,
            "core.alternateRefsCommand": tool,
            "log.showSignature": "true", "gpg.program": tool, "gpg.ssh.program": tool, "gpg.x509.program": tool,
            "credential.helper": "!" + tool,
            "diff.external": tool, "diff.evil.command": tool, "diff.evil.textconv": tool,
            "filter.evil.clean": tool, "filter.evil.smudge": tool, "filter.evil.process": tool,
            "uploadpack.packObjectsHook": tool,
            "alias.remote-": "!" + tool,
            "protocol.allow": "always", "protocol.file.allow": "always", "protocol.ext.allow": "always",
        ]
        if partialClone {
            // A partial clone that fetches what it misses, with our tool as the program that fetches.
            settings.merge([
                "core.repositoryformatversion": "1", "extensions.partialClone": "origin",
                "remote.origin.url": root + "/" + name, "remote.origin.promisor": "true", "remote.origin.uploadpack": tool,
                "remote.ext.url": "ext::" + tool, "remote.ext.promisor": "true",
                "remote.nameless.url": "x", "remote.nameless.promisor": "true", "remote.nameless.vcs": "",
                "remote.slash.url": "x", "remote.slash.promisor": "true", "remote.slash.vcs": "/",
            ]) { _, new in new }
        }
        for (key, value) in settings { sh(["config", key, value], in: name) }
        if partialClone {
            // A branch that points at a commit the repository doesn't have: the thing a partial clone fetches.
            write(name + "/.git/refs/heads/ghost", "1234567890123456789012345678901234567890\n")
        }
        // A tracked file that changed, so anything that compares contents would start the filter.
        write(name + "/src/index.js", "console.log(2)")
    }

    /// What plain git prints, trimmed.
    func output(_ args: [String], in dir: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git.binary)
        p.arguments = ["-C", root + "/" + dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAHostileRepositoryCantRunAnything() {
        let marker = root + "/RAN"
        let tool = script("tool.sh", "#!/bin/sh\necho ran >> '\(marker)'\nexit 1\n")
        let binaries = Git.candidates.filter { fm.isExecutableFile(atPath: $0) }
        XCTAssertFalse(binaries.isEmpty)
        for (i, binary) in binaries.enumerated() {
            for partialClone in [false, true] {
                let name = "hostile-\(i)-\(partialClone ? "partial" : "signed")"
                let what = "\(binary), \(partialClone ? "partial clone" : "signed commit")"
                hostileRepository(name, tool: tool, partialClone: partialClone)
                let repo = root + "/" + name

                // The trap works: asked the plain way, git runs the tool. For the signed commit
                // that is the signature check; for the partial clone, the fetch of what is missing.
                plainGit(binary, ["log", "--all", "-1", "--format=%ct"], in: name)
                XCTAssertTrue(fm.fileExists(atPath: marker), "\(what): the repository should run the tool for a plain git log")
                try? fm.removeItem(atPath: marker)
                plainGit(binary, ["status", "--porcelain"], in: name)
                XCTAssertTrue(fm.fileExists(atPath: marker), "\(what): the repository should run the tool for a plain git status")
                try? fm.removeItem(atPath: marker)

                // Asked Sweep's way, nothing runs. Every question Sweep can ask:
                let git = Git(binary: binary)
                XCTAssertFalse(git.hasTrackedFiles("node_modules", in: repo), what)
                XCTAssertTrue(git.hasTrackedFiles("src", in: repo), what)
                XCTAssertTrue(git.tracksAny(of: ["package.json"], in: repo), what)
                XCTAssertTrue(git.isIgnored("node_modules", in: repo), what)
                if partialClone {
                    XCTAssertEqual(git.lastCommit(in: repo), .unknown, "\(what): a branch git can't read must not be guessed around")
                } else if case .date(let date) = git.lastCommit(in: repo) {
                    XCTAssertGreaterThan(date, Date(), "\(what): the signed commit is the newest one")
                } else {
                    XCTFail("\(what): the newest commit should be found without checking its signature")
                }
                XCTAssertFalse(git.isPristineCheckout(repo), what)
                // …and each command behind them, also the ones a failed earlier step would skip.
                for command in [["rev-list", "--max-count=1", "--no-show-signature", "--all", "--not", "--remotes", "--tags"],
                                ["rev-list", "--max-count=1", "--timestamp", "--no-show-signature", "signed"],
                                ["diff-index", "--cached", "--quiet", "HEAD", "--"],
                                ["ls-files", "-z", "--others"], ["ls-files", "-z", "--stage", "--debug"]] {
                    git.run(command, in: repo)
                }
                // The scanner, the safety checks and the cleaner on top of them.
                let scanner = ProjectScanner(roots: [repo], git: git, home: root)
                let project = scanner.scan(index: emptyIndex).projects.first
                XCTAssertNotNil(project, what)
                XCTAssertEqual(project?.activitySource, partialClone ? .unknown : .commit, what)
                if let project { _ = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project) }
                XCTAssertFalse(fm.fileExists(atPath: marker), "\(what): ran a program named by the repository")
                try? fm.removeItem(atPath: marker)
            }
        }
    }

    func testGitOnlyGetsAMinimalEnvironment() {
        nodeProject()
        setenv("GIT_DIR", "/nonexistent", 1)
        setenv("GIT_EXTERNAL_DIFF", "/nonexistent", 1)
        defer { unsetenv("GIT_DIR"); unsetenv("GIT_EXTERNAL_DIFF") }
        let env = Git.environment(for: root + "/site")
        XCTAssertNil(env["GIT_DIR"])
        XCTAssertNil(env["GIT_EXTERNAL_DIFF"])
        XCTAssertEqual(env["GIT_NO_LAZY_FETCH"], "1")
        XCTAssertEqual(env["GIT_ALLOW_PROTOCOL"], "/", "an empty list would allow a remote helper without a name")
        XCTAssertEqual(env["GIT_CEILING_DIRECTORIES"], root)
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        // With GIT_DIR set in this process, a real question still gets its answer from the right repository.
        XCTAssertTrue(git.hasTrackedFiles("src", in: root + "/site"))
        XCTAssertFalse(git.hasTrackedFiles("node_modules", in: root + "/site"))
        // Nothing weakens git's own check on who owns a repository.
        XCTAssertFalse(Git.overrides.contains { $0.lowercased().hasPrefix("safe.") })
    }

    func testOnlyTheRepositoryInTheFolderAnswers() {
        nodeProject("outer")
        write("outer/inner/package.json", "{}")
        try! fm.createDirectory(atPath: root + "/outer/inner/.git", withIntermediateDirectories: true)   // not a repository
        // git must not go up to `outer` and answer for that one.
        XCTAssertTrue(git.hasTrackedFiles("node_modules", in: root + "/outer/inner"), "no answer counts as tracked")
        XCTAssertEqual(git.lastCommit(in: root + "/outer/inner"), .unknown)
    }

    func testAGitThatHangsIsStoppedAndCountsAsFailure() {
        nodeProject()
        var slow = Git(binary: script("slow-git", "#!/bin/sh\nsleep 30\n"))
        slow.timeout = 0.5
        let started = Date()
        XCTAssertTrue(slow.hasTrackedFiles("node_modules", in: root + "/site"), "no answer: the folder counts as tracked")
        XCTAssertFalse(slow.tracksAny(of: ["package.json"], in: root + "/site"))
        XCTAssertFalse(slow.isIgnored("node_modules", in: root + "/site"))
        XCTAssertEqual(slow.lastCommit(in: root + "/site"), .unknown)
        XCTAssertFalse(slow.isPristineCheckout(root + "/site"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // Nothing is offered, and the project doesn't look unused.
        XCTAssertTrue(ProjectScanner(roots: [root], git: slow, home: root).scan(index: emptyIndex).projects.isEmpty)
        let activity = Activity.last(project: root + "/site", isGit: true, artifacts: [], skip: [], git: slow, index: emptyIndex)
        XCTAssertEqual(activity.source, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(activity.date), 60)
    }

    func testTooMuchOutputStopsTheProgram() {
        let result = Subprocess.run("/usr/bin/yes", [], environment: [:], timeout: 20, outputLimit: 10_000)
        XCTAssertEqual(result.status, Subprocess.stopped)
        XCTAssertEqual(Subprocess.run("/usr/bin/true", [], environment: [:], timeout: 20, outputLimit: 10).status, 0)
        XCTAssertEqual(Subprocess.run("/usr/bin/false", [], environment: [:], timeout: 20, outputLimit: 10).status, 1)
        XCTAssertEqual(Subprocess.run("/nonexistent/tool", [], environment: [:], timeout: 20, outputLimit: 10).status, Subprocess.notStarted)
        let env = Subprocess.run("/usr/bin/env", [], environment: ["ONLY": "this"], timeout: 20, outputLimit: 10_000)
        XCTAssertEqual(String(decoding: env.output, as: UTF8.self), "ONLY=this\n")
    }

    func testTrackedFilesAreFoundWhateverTheirCase() throws {
        try XCTSkipIf(Paths.isCaseSensitive(at: root), "The temporary folder is on a disk that tells Build from build.")
        write("app/package.json", "{}")
        write("app/package-lock.json", "{}")
        write("app/Build/shipped.js", "kept in git")
        repo("app", ignore: "node_modules/\n")
        // The folder gets its lower-case name on disk; git still knows the file as Build/shipped.js.
        try fm.moveItem(atPath: root + "/app/Build", toPath: root + "/app/build-tmp")
        try fm.moveItem(atPath: root + "/app/build-tmp", toPath: root + "/app/build")
        XCTAssertTrue(git.hasTrackedFiles("build", in: root + "/app"))
        XCTAssertNil(artifact(scan(), "app", "build"), "a folder with tracked files is never offered")
    }

    func testPathsAreTakenAsWrittenNotAsPatterns() {
        write("app/package.json", "{}")
        write("app/package-lock.json", "{}")
        write("app/pages/[id]/package.json", "{}")
        write("app/pages/[id]/node_modules/x/i.js")
        write("app/pages/i/package.json", "{}")           // what `[id]` would match as a pattern
        repo("app", ignore: "node_modules/\n")
        sh(["--literal-pathspecs", "rm", "-q", "--cached", "pages/[id]/package.json"], in: "app")
        sh(["commit", "-q", "-m", "untrack"], in: "app")
        XCTAssertFalse(git.tracksAny(of: ["pages/[id]/package.json"], in: root + "/app"))
        XCTAssertTrue(git.tracksAny(of: ["pages/i/package.json"], in: root + "/app"))
        XCTAssertTrue(git.isIgnored("pages/[id]/node_modules", in: root + "/app"))
    }

    // MARK: - A project that isn't in git, inside a repository

    func testAnUnversionedProjectInAnIgnoredFolderAsks() {
        nodeProject("repo", ignore: "node_modules/\n.next/\nscratch/\n")
        write("repo/scratch/old-site/package.json", #"{"devDependencies":{"vite":"5"}}"#)
        write("repo/scratch/old-site/package-lock.json", "{}")
        write("repo/scratch/old-site/dist/site.js", "the only copy")
        write("repo/scratch/old-site/node_modules/x/i.js")
        let project = scan()[0]
        let dist = project.artifacts.first { $0.relativePath == "scratch/old-site/dist" }
        XCTAssertEqual(dist?.tier, .ask)
        XCTAssertEqual(dist?.reason, "package.json next to it isn't in git")
        XCTAssertEqual(project.artifacts.first { $0.relativePath == "scratch/old-site/node_modules" }?.tier, .ask)
        // The repository's own folders are as safe as before.
        XCTAssertEqual(project.artifacts.first { $0.relativePath == "node_modules" }?.tier, .safe)
        // Automatic cleanup takes the safe ones only.
        let safe = project.safeArtifacts(kinds: Set(ArtifactKind.allCases))
        XCTAssertEqual(Set(safe.map(\.relativePath)), ["node_modules", ".next"])
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project)
        XCTAssertEqual(Set(result.removed.map(\.relativePath)), ["node_modules", ".next"])
        XCTAssertTrue(fm.fileExists(atPath: root + "/repo/scratch/old-site/dist/site.js"))
    }

    func testAProjectWhoseMarkerIsNotCommittedYetAsks() {
        nodeProject()
        write("site/tools/package.json", "{}")
        write("site/tools/package-lock.json", "{}")
        write("site/tools/node_modules/x/i.js")
        XCTAssertEqual(artifact(scan(), "site", "tools/node_modules")?.tier, .ask)
        // Staged counts: git has the file.
        sh(["add", "tools/package.json"], in: "site")
        XCTAssertEqual(artifact(scan(), "site", "tools/node_modules")?.tier, .safe)
    }

    // MARK: - Everyday names need a sign of their toolchain

    /// A project with `files` committed, and `artifact` ignored and holding `inside`.
    func outputProject(_ name: String, files: [String: String], artifact: String, inside: [String]) {
        for (path, text) in files { write(name + "/" + path, text) }
        for path in inside { write(name + "/" + artifact + "/" + path) }
        repo(name, ignore: artifact + "/\n")
    }

    func testEverydayFolderNamesNeedEvidence() {
        struct Case {
            let label: String
            let files: [String: String]
            let artifact: String
            /// Looks like a folder of one's own.
            let plain: [String]
            /// What the toolchain leaves in it.
            let made: [String]
        }
        let lock = ["package.json": "{}", "package-lock.json": "{}"]
        let cases = [
            Case(label: "node-dist", files: lock, artifact: "dist", plain: ["notes.txt"], made: ["index.js", "index.js.map"]),
            Case(label: "node-build", files: lock, artifact: "build", plain: ["release.zip"], made: ["asset-manifest.json", "static/js/main.js"]),
            Case(label: "node-out", files: lock, artifact: "out", plain: ["report.pdf"], made: ["_next/static/x.js", "index.html"]),
            Case(label: "node-cache", files: lock, artifact: ".cache", plain: ["downloads/big.bin"], made: ["redux/redux.state"]),
            Case(label: "node-coverage", files: lock, artifact: "coverage", plain: ["map.png"], made: ["lcov.info"]),
            Case(label: "php", files: ["composer.json": "{}", "composer.lock": "{}"], artifact: "vendor", plain: ["acme/lib/a.php"], made: ["autoload.php", "acme/lib/a.php"]),
            Case(label: "go", files: ["go.mod": "module x", "go.sum": ""], artifact: "vendor", plain: ["x/y.go"], made: ["modules.txt", "x/y.go"]),
            Case(label: "gradle", files: ["build.gradle": ""], artifact: "build", plain: ["notes.txt"], made: ["classes/java/main/A.class"]),
            Case(label: "maven", files: ["pom.xml": "<project/>"], artifact: "target", plain: ["notes.txt"], made: ["classes/A.class"]),
            Case(label: "dotnet-bin", files: ["App.csproj": "<Project/>"], artifact: "bin", plain: ["deploy.sh"], made: ["Debug/net8.0/App.dll"]),
            Case(label: "dotnet-obj", files: ["App.csproj": "<Project/>"], artifact: "obj", plain: ["model.obj"], made: ["project.assets.json"]),
            Case(label: "flutter", files: ["pubspec.yaml": "name: x"], artifact: "build", plain: ["notes.txt"], made: ["flutter_assets/AssetManifest.json"]),
            Case(label: "elixir", files: ["mix.exs": "", "mix.lock": ""], artifact: "deps", plain: ["notes.txt"], made: ["jason/mix.exs"]),
        ]
        for c in cases {
            outputProject(c.label + "-plain", files: c.files, artifact: c.artifact, inside: c.plain)
            outputProject(c.label + "-made", files: c.files, artifact: c.artifact, inside: c.made)
        }
        let projects = scan()
        for c in cases {
            let plain = artifact(projects, c.label + "-plain", c.artifact)
            XCTAssertEqual(plain?.tier, .ask, c.label)
            XCTAssertEqual(plain?.reason, "Can't tell what made it", c.label)
            XCTAssertEqual(artifact(projects, c.label + "-made", c.artifact)?.tier, .safe, c.label)
        }
    }

    func testABuildToolOrConfigThatNamesTheFolderIsEvidence() {
        // What the project's own files say, for a folder with nothing recognisable in it.
        let cases: [(label: String, files: [String: String], artifact: String, safe: Bool)] = [
            ("vite", ["package.json": #"{"devDependencies": {"vite": "^5.0.0"}}"#], "dist", true),
            ("cra", ["package.json": #"{"dependencies": {"react-scripts": "5.0.1"}}"#], "build", true),
            ("next-export", ["package.json": #"{"dependencies": {"next": "14"}}"#], "out", true),
            ("tsc", ["package.json": "{}", "tsconfig.json": "{ // comment\n  \"compilerOptions\": { \"outDir\": \"./dist\" } }"], "dist", true),
            ("webpack", ["package.json": "{}", "webpack.config.js": "module.exports = { output: { path: path.resolve(__dirname, 'build') } }"], "build", true),
            ("rollup", ["package.json": "{}", "rollup.config.mjs": "export default { output: { dir: 'dist' } }"], "dist", true),
            ("main-field", ["package.json": #"{"main": "dist/index.js"}"#], "dist", true),
            ("files-field", ["package.json": #"{"files": ["lib", "out"]}"#], "out", true),
            ("flag", ["package.json": #"{"scripts": {"compile": "babel src -d build"}}"#], "build", true),
            ("clean-script", ["package.json": #"{"scripts": {"clean": "rimraf coverage build"}}"#], "build", true),
            ("jest-config", ["package.json": "{}", "jest.config.js": "module.exports = { coverageDirectory: 'coverage' }"], "coverage", true),
            ("gatsby", ["package.json": #"{"dependencies": {"gatsby": "5"}}"#], ".cache", true),
            // Not evidence: "build" as the name of a script or a command, another folder's name, another tool.
            ("script-name", ["package.json": #"{"scripts": {"build": "vite build", "prebuild": "echo build"}}"#], "build", false),
            ("other-folder", ["package.json": #"{"main": "lib/index.js", "scripts": {"x": "tsc --outDir lib"}}"#], "dist", false),
            ("longer-name", ["package.json": #"{"main": "dist-old/index.js", "files": ["distribution"]}"#], "dist", false),
            ("no-default", ["package.json": #"{"dependencies": {"react-scripts": "5.0.1"}}"#], "dist", false),
        ]
        for c in cases {
            var files = c.files
            files["package-lock.json"] = "{}"
            outputProject(c.label, files: files, artifact: c.artifact, inside: ["thing.bin"])
        }
        let projects = scan()
        for c in cases {
            XCTAssertEqual(artifact(projects, c.label, c.artifact)?.tier, c.safe ? .safe : .ask, c.label)
        }
    }

    func testPatternsForEvidence() {
        XCTAssertTrue(Evidence.fits("*.d.ts", "index.d.ts"))
        XCTAssertFalse(Evidence.fits("*.d.ts", "index.ts"))
        XCTAssertTrue(Evidence.fits("*-darwin-*", "App-darwin-arm64"))
        XCTAssertFalse(Evidence.fits("*-darwin-*", "darwin"))
        XCTAssertTrue(Evidence.fits("lcov.info", "lcov.info"))
        XCTAssertTrue(Evidence.fitsPath("checkouts/*", "checkouts/swift-log"))
        XCTAssertFalse(Evidence.fitsPath("checkouts/*", "checkouts/swift-log/Sources"))
        XCTAssertFalse(Evidence.fitsPath("checkouts/*", "repositories/swift-log"))
        XCTAssertTrue(Evidence.isBuildConfig("vite.config.ts"))
        XCTAssertTrue(Evidence.isBuildConfig("tsconfig.build.json"))
        XCTAssertFalse(Evidence.isBuildConfig("README.md"))
        // A symlinked folder isn't looked into.
        write("real/inner/lcov.info")
        try! fm.createDirectory(atPath: root + "/cov", withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: root + "/cov/sub", withDestinationPath: root + "/real/inner")
        XCTAssertFalse(Evidence.exists("sub/lcov.info", in: root + "/cov"))
        XCTAssertTrue(Evidence.exists("*/lcov.info", in: root + "/real"))
    }

    // MARK: - Git repositories inside a removable folder

    func testAGitRepositoryDeepInsideAsks() {
        nodeProject()
        write("site/node_modules/@scope/pkg/work/.git/HEAD", "ref: refs/heads/main")
        write("site/node_modules/@scope/pkg/work/thesis.txt", "years of work")
        let project = scan()[0]
        let modules = project.artifacts.first { $0.name == "node_modules" }!
        XCTAssertEqual(modules.tier, .ask)
        XCTAssertEqual(modules.reason, "Holds a git repository (@scope/pkg/work)")
        // Automatic cleanup leaves it; a click still removes it.
        let cleaner = Cleaner(git: git, removal: .delete)
        XCTAssertTrue(cleaner.clean([modules], in: project).removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/node_modules/@scope/pkg/work/thesis.txt"))
        XCTAssertEqual(cleaner.clean([modules], in: project, allowAsk: true).removed.count, 1)
    }

    func testAGitFileOfASubmoduleCountsToo() {
        nodeProject()
        write("site/.next/sub/.git", "gitdir: ../../.git/modules/sub")
        XCTAssertEqual(artifact(scan(), "site", ".next")?.tier, .ask)
    }

    func testAFolderTooBigToSearchIsNotSafe() {
        nodeProject()
        for i in 0..<30 { write("site/node_modules/pkg\(i)/index.js") }
        XCTAssertEqual(Safety.repositories(in: root + "/site/node_modules", limit: 1_000), [])
        XCTAssertNil(Safety.repositories(in: root + "/site/node_modules", limit: 20))
        XCTAssertNil(Safety.repositories(in: root + "/site/nope"))
        // A symlink is not followed, and a repository's own insides are not searched.
        write("elsewhere/.git/HEAD")
        try! fm.createSymbolicLink(atPath: root + "/site/node_modules/link", withDestinationPath: root + "/elsewhere")
        write("site/node_modules/a/.git/modules/b/.git/HEAD")
        XCTAssertEqual(Safety.repositories(in: root + "/site/node_modules"), ["a"])
    }

    func testAFolderThatCantBeReadCompletelyAsks() throws {
        nodeProject()
        let locked = root + "/site/node_modules/locked"
        write("site/node_modules/locked/inner/file.js")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        try XCTSkipIf(fm.isReadableFile(atPath: locked), "This account reads every folder.")
        let modules = artifact(scan(), "site", "node_modules")
        XCTAssertEqual(modules?.tier, .ask, "nobody knows what is in there")
        XCTAssertEqual(modules?.reason, "Too big or unreadable, so it can't be checked for git repositories inside")
    }

    func testAFolderWhoseRealNameIsSpelledDifferentlyIsNotOnTheList() throws {
        try XCTSkipIf(Paths.isCaseSensitive(at: root), "The temporary folder is on a disk that tells Build from build.")
        nodeProject()
        let project = scan()[0]
        // After the scan the folder gets another spelling; the old path still finds it.
        try fm.moveItem(atPath: root + "/site/node_modules", toPath: root + "/site/renaming")
        try fm.moveItem(atPath: root + "/site/renaming", toPath: root + "/site/Node_Modules")
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/node_modules/left-pad/index.js"))
        let modules = project.artifacts.first { $0.name == "node_modules" }!
        let result = Cleaner(git: git, removal: .delete).clean([modules], in: project, allowAsk: true)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/Node_Modules/left-pad/index.js"))
        XCTAssertNil(artifact(scan(), "site", "Node_Modules"))
    }

    /// A Swift package whose `.build` holds a dependency the way SwiftPM checks one out.
    func swiftPackage(_ name: String) {
        if !fm.fileExists(atPath: root + "/dep-origin") {
            write("dep-origin/Package.swift", "// dep")
            write("dep-origin/Sources/Dep/Dep.swift", "public let dep = 1")
            repo("dep-origin", ignore: ".build/\n")
            sh(["tag", "1.0.0"], in: "dep-origin")
        }
        write(name + "/Package.swift", "// swift-tools-version:5.9")
        write(name + "/Sources/App/main.swift", "print(1)")
        write(name + "/.build/debug/App", "binary")
        repo(name, ignore: ".build/\n")
        sh(["clone", "-q", root + "/dep-origin", root + "/" + name + "/.build/checkouts/dep"], in: name)
        sh(["checkout", "-q", "--detach", "1.0.0"], in: name + "/.build/checkouts/dep")
    }

    func testAPackageManagersUntouchedCheckoutGoesWithTheFolder() {
        swiftPackage("clean")
        swiftPackage("edited")
        write("edited/.build/checkouts/dep/Sources/Dep/Dep.swift", "public let dep = 2 // my fix")
        swiftPackage("added")
        write("added/.build/checkouts/dep/Sources/Dep/Mine.swift", "let mine = 1")
        swiftPackage("committed")
        write("committed/.build/checkouts/dep/Sources/Dep/Dep.swift", "public let dep = 3")
        sh(["commit", "-q", "-am", "my change"], in: "committed/.build/checkouts/dep")
        swiftPackage("staged")
        write("staged/.build/checkouts/dep/Sources/Dep/Dep.swift", "public let dep = 4")
        sh(["add", "-A"], in: "staged/.build/checkouts/dep")
        swiftPackage("deleted")
        try! fm.removeItem(atPath: root + "/deleted/.build/checkouts/dep/Sources/Dep/Dep.swift")
        swiftPackage("elsewhere")
        sh(["clone", "-q", root + "/dep-origin", root + "/elsewhere/.build/mine/dep"], in: "elsewhere")

        let projects = scan().filter { $0.name != "dep-origin" }
        XCTAssertEqual(projects.count, 7)
        XCTAssertEqual(artifact(projects, "clean", ".build")?.tier, .safe)
        for name in ["edited", "added", "committed", "staged", "deleted"] {
            XCTAssertEqual(artifact(projects, name, ".build")?.tier, .ask, name)
            XCTAssertEqual(artifact(projects, name, ".build")?.reason, "A dependency in it (checkouts/dep) has changes of its own", name)
        }
        // A clone where SwiftPM doesn't put one is someone's own, however clean it is.
        XCTAssertEqual(artifact(projects, "elsewhere", ".build")?.reason, "Holds a git repository (mine/dep)")
        // Without git nothing about a checkout can be known.
        let blind = ProjectScanner(roots: [root + "/clean"], git: nil, home: root).scan(index: emptyIndex).projects
        XCTAssertEqual(blind.first?.artifacts.first?.tier, .ask)
    }

    func testAFileThatWasOnlyTouchedCountsAsChanged() {
        swiftPackage("touched")
        let file = root + "/touched/.build/checkouts/dep/Sources/Dep/Dep.swift"
        XCTAssertTrue(git.isPristineCheckout(root + "/touched/.build/checkouts/dep"))
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5_000)], ofItemAtPath: file)
        XCTAssertFalse(git.isPristineCheckout(root + "/touched/.build/checkouts/dep"))
        XCTAssertFalse(Git.matchesDisk("garbage", in: root))
        XCTAssertTrue(Git.matchesDisk("", in: root))
    }

    // MARK: - Paths

    func testPathsAreSpelledAsTheDiskHasThem() throws {
        write("Code/Site/file.txt")
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/Code")
        XCTAssertEqual(Paths.canonical(root + "/link/Site"), root + "/Code/Site")
        XCTAssertEqual(Paths.canonical(root + "/Code/Site/"), root + "/Code/Site")
        XCTAssertEqual(Paths.canonical(root + "/Code/missing/deeper"), root + "/Code/missing/deeper")
        XCTAssertEqual(Paths.canonical(root + "/link/missing"), root + "/Code/missing")
        XCTAssertEqual(Paths.canonical("/"), "/")
        XCTAssertTrue(Paths.isInside("/a/b/c", "/a/b", caseSensitive: true))
        XCTAssertTrue(Paths.isInside("/a/b", "/a/b", caseSensitive: true))
        XCTAssertFalse(Paths.isInside("/a/bc", "/a/b", caseSensitive: true))
        XCTAssertFalse(Paths.isInside("/a/B/c", "/a/b", caseSensitive: true))
        XCTAssertTrue(Paths.isInside("/a/B/c", "/a/b", caseSensitive: false))
        XCTAssertFalse(Paths.same("/a/B", "/a/b", caseSensitive: true))
        XCTAssertTrue(Paths.same("/a/B", "/a/b", caseSensitive: false))

        try XCTSkipIf(Paths.isCaseSensitive(at: root), "The temporary folder is on a disk that tells Code from code.")
        XCTAssertEqual(Paths.canonical(root + "/code/SITE"), root + "/Code/Site")
        XCTAssertEqual(Paths.canonical(root + "/CODE/site/new"), root + "/Code/Site/new")
        XCTAssertTrue(Paths.same(root + "/code", root + "/Code"))
        XCTAssertEqual(Paths.canonical([root + "/code", root + "/Code", root + "/link"]), [root + "/Code"])
    }

    func testAFolderStoredInTheWrongCaseStillCountsAsInUseAndExcluded() throws {
        try XCTSkipIf(Paths.isCaseSensitive(at: root), "The temporary folder is on a disk that tells Code from code.")
        nodeProject("Code/site")
        nodeProject("Code/other")
        // The root as an earlier version could have stored it.
        let stored = root + "/code"
        // macOS reports a running program's folder as the disk spells it.
        let index = ActivityIndex(workingDirectories: [root + "/Code/site/src"])
        let projects = ProjectScanner(roots: [stored], git: git, home: root).scan(index: index).projects
        XCTAssertEqual(projects.map(\.path).sorted(), [root + "/Code/other", root + "/Code/site"])
        XCTAssertEqual(projects.first { $0.name == "site" }?.inUse, true)
        XCTAssertEqual(projects.first { $0.name == "other" }?.inUse, false)
        // The other way round as well: the project path in one spelling, the program's in another.
        XCTAssertTrue(ActivityIndex(workingDirectories: [root + "/Code/site"]).inUse(root + "/code/SITE"))
        // "Never look in", typed in another case.
        let skipping = ProjectScanner(roots: [stored], excluded: [root + "/CODE/Site"], git: git, home: root).scan(index: emptyIndex).projects
        XCTAssertEqual(skipping.map(\.name), ["other"])
        // Looking a project up again before cleaning finds it under either spelling.
        XCTAssertEqual(ProjectScanner(roots: [stored], git: git, home: root).rescan(project: root + "/code/SITE", index: index)?.path, root + "/Code/site")
    }

    func testStoredFoldersAreRewrittenAsTheDiskHasThem() throws {
        try fm.createDirectory(atPath: root + "/home/Code/site", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/home/Documents", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root + "/home/Projects", withDestinationPath: root + "/home/Code")
        // "Code", "code" and the link "Projects" are one folder.
        let roots = SweepSettings.defaultRoots(home: root + "/home")
        XCTAssertEqual(roots, [root + "/home/Code", root + "/home/Documents"])

        var settings = SweepSettings()
        settings.roots = [root + "/home/Projects", root + "/home/Code", root + "/gone"]
        settings.excluded = [root + "/home/Projects/site"]
        XCTAssertEqual(settings.canonical().roots, [root + "/home/Code", root + "/gone"])
        XCTAssertEqual(settings.canonical().excluded, [root + "/home/Code/site"])

        var state = SweepState()
        state.pinned = [root + "/home/Projects/site", "/gone/project"]
        state.kept = [root + "/home/Projects/site": Date(timeIntervalSince1970: 100), root + "/home/Code/site": Date(timeIntervalSince1970: 200)]
        state.customIdleDays = [root + "/home/Projects/site": 30]
        let migrated = state.canonical()
        XCTAssertEqual(migrated.pinned, [root + "/home/Code/site", "/gone/project"], "a pin survives under the path the scanner will report")
        XCTAssertEqual(migrated.kept, [root + "/home/Code/site": Date(timeIntervalSince1970: 200)])
        XCTAssertEqual(migrated.customIdleDays, [root + "/home/Code/site": 30])

        let project = Project(path: root + "/home/Projects/site", name: "site", isGit: true, ecosystems: ["Node"],
                              artifacts: [Artifact(path: root + "/home/Projects/site/node_modules", relativePath: "node_modules",
                                                   name: "node_modules", ecosystem: "Node", kind: .dependencies, tier: .safe)],
                              lastActivity: Date(), activitySource: .commit).canonical()
        XCTAssertEqual(project.path, root + "/home/Code/site")
        XCTAssertEqual(project.artifacts[0].path, root + "/home/Code/site/node_modules")

        try XCTSkipIf(Paths.isCaseSensitive(at: root), "The temporary folder is on a disk that tells Code from code.")
        state.pinned = [root + "/home/code/SITE"]
        XCTAssertEqual(state.canonical().pinned, [root + "/home/Code/site"])
    }

    // MARK: - In use

    func testAProgramRunningInTheProjectIsActivity() {
        nodeProject(committed: Date().addingTimeInterval(-200 * 86_400))
        age("site", days: 200)
        let idle = scan()[0]
        XCTAssertGreaterThan(Format.days(since: idle.lastActivity), 100)
        let used = scan(index: ActivityIndex(workingDirectories: [root + "/site"]))[0]
        XCTAssertTrue(used.inUse)
        XCTAssertEqual(used.activitySource, .running)
        XCTAssertEqual(Format.days(since: used.lastActivity), 0)
        // Seen running a week ago: the idle period counts from then, not from the last changed file.
        var state = SweepState()
        state.lastInUse[idle.path] = Date().addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(Planner.status(of: idle, settings: SweepSettings(), state: state), .active(daysLeft: 53))
        XCTAssertFalse(Planner.isDue(idle, settings: SweepSettings(), state: state))
        XCTAssertTrue(Planner.isDue(idle, settings: SweepSettings(), state: SweepState()))
    }

    func testAProgramThatStartsWhileCleaningStopsTheRest() {
        nodeProject()
        let project = scan()[0]
        var cleaner = Cleaner(git: git, removal: .delete)
        let directory = root + "/site/src"
        cleaner.workingDirectories = { [directory] }
        let result = cleaner.clean(project.artifacts, in: project, allowAsk: true)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.skipped.first?.reason, "A program is running in the project")
        XCTAssertTrue(fm.fileExists(atPath: root + "/site/node_modules"))
    }

    // MARK: - Removing

    func testRemovingDeletesOnlyWhatIsInsideTheFolder() throws {
        nodeProject()
        write("precious/thesis.txt", "years of work")
        write("site/node_modules/deep/a/b/c/d/file.js")
        try fm.createSymbolicLink(atPath: root + "/site/node_modules/deep/link-to-folder", withDestinationPath: root + "/precious")
        try fm.createSymbolicLink(atPath: root + "/site/node_modules/link-to-file", withDestinationPath: root + "/precious/thesis.txt")
        try fm.createSymbolicLink(atPath: root + "/site/node_modules/dangling", withDestinationPath: root + "/nope")
        let project = scan()[0]
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: root + "/site/node_modules"))
        XCTAssertEqual(try String(contentsOfFile: root + "/precious/thesis.txt", encoding: .utf8), "years of work")
    }

    func testAProjectReachedThroughASymlinkIsRemovedWhereItReallyIs() throws {
        nodeProject("real/site")
        try fm.createSymbolicLink(atPath: root + "/shortcut", withDestinationPath: root + "/real")
        // A project as an earlier scan could have stored it: by the path through the link.
        let found = scan([root + "/real"])[0]
        var project = found
        project.path = root + "/shortcut/site"
        project.artifacts = found.artifacts.map { var a = $0; a.path = root + "/shortcut/site/" + a.relativePath; return a }
        let result = Cleaner(git: git, removal: .delete).clean(project.artifacts, in: project)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: root + "/real/site/node_modules"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/real/site/src/index.js"))
    }

    func testAFolderSwappedAfterTheCheckIsNotRemoved() throws {
        nodeProject()
        write("precious/node_modules/thesis.txt", "years of work")
        let folder = root + "/site/node_modules"
        // Checked as a real folder; then the folder is replaced by a link…
        try fm.moveItem(atPath: folder, toPath: root + "/moved-away")
        try fm.createSymbolicLink(atPath: folder, withDestinationPath: root + "/precious/node_modules")
        XCTAssertThrowsError(try Remover.remove(folder, inside: root + "/site", removal: .delete))
        XCTAssertTrue(fm.fileExists(atPath: root + "/precious/node_modules/thesis.txt"))
        // …or the project folder itself is, so the same path now leads somewhere else.
        try fm.removeItem(atPath: folder)
        try fm.moveItem(atPath: root + "/site", toPath: root + "/site-real")
        try fm.createSymbolicLink(atPath: root + "/site", withDestinationPath: root + "/precious")
        XCTAssertThrowsError(try Remover.remove(folder, inside: root + "/site", removal: .delete))
        XCTAssertThrowsError(try Remover.remove(folder, inside: root + "/site", removal: .trash))
        XCTAssertTrue(fm.fileExists(atPath: root + "/precious/node_modules/thesis.txt"))
        // A folder outside the project is refused even when the path is honest.
        XCTAssertThrowsError(try Remover.remove(root + "/precious/node_modules", inside: root + "/site-real", removal: .delete))
        XCTAssertTrue(fm.fileExists(atPath: root + "/precious/node_modules/thesis.txt"))
    }

    // MARK: - Saved state

    func testAnUnreadableStateIsKeptAsideAndSwitchesAutomaticOff() throws {
        let store = Store(directory: URL(fileURLWithPath: root + "/store"))
        var settings = SweepSettings()
        settings.automatic = true
        store.settings = settings
        try "{ not json".write(toFile: root + "/store/state.json", atomically: true, encoding: .utf8)

        let loaded = store.loadState()
        XCTAssertTrue(loaded.damaged)
        XCTAssertTrue(loaded.state.pinned.isEmpty)
        XCTAssertNotNil(loaded.state.recovery)
        XCTAssertFalse(store.settings.automatic, "with the pins unknown nothing may be cleaned automatically")
        let aside = try fm.contentsOfDirectory(atPath: root + "/store").filter { $0.hasPrefix("state.corrupt-") && $0.hasSuffix(".json") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOfFile: root + "/store/" + aside[0], encoding: .utf8), "{ not json")
        XCTAssertTrue(loaded.state.recovery?.contains(aside[0]) ?? false)
        // Told once: the next start reads the state that was written in its place.
        let again = store.loadState()
        XCTAssertFalse(again.damaged)
        XCTAssertEqual(again.state.recovery, loaded.state.recovery, "the message stays until the user dismisses it")
    }

    func testADamagedPinListKeepsWhatCanBeReadAndSwitchesAutomaticOff() throws {
        let store = Store(directory: URL(fileURLWithPath: root + "/store"))
        var settings = SweepSettings()
        settings.automatic = true
        store.settings = settings
        try #"{"pinned": ["/a/x", 5, "/a/y"], "customIdleDays": {"/a/z": 90}, "pending": {"/a/q": "2026-01-01T00:00:00Z"}}"#
            .write(toFile: root + "/store/state.json", atomically: true, encoding: .utf8)
        let loaded = store.loadState()
        XCTAssertTrue(loaded.damaged)
        XCTAssertEqual(loaded.state.pinned, ["/a/x", "/a/y"])
        XCTAssertEqual(loaded.state.customIdleDays, ["/a/z": 90])
        XCTAssertTrue(loaded.state.pending.isEmpty, "nothing stays scheduled")
        XCTAssertFalse(store.settings.automatic)
    }

    func testOneDamagedFieldDoesntDropThePins() throws {
        let store = Store(directory: URL(fileURLWithPath: root + "/store"))
        var settings = SweepSettings()
        settings.automatic = true
        store.settings = settings
        try #"{"pinned": ["/a/x"], "pending": "oops", "lastScan": 12, "kept": {"/a/k": "2026-01-01T00:00:00Z"}, "someNewField": 1}"#
            .write(toFile: root + "/store/state.json", atomically: true, encoding: .utf8)
        let loaded = store.loadState()
        XCTAssertFalse(loaded.damaged)
        XCTAssertEqual(loaded.state.pinned, ["/a/x"])
        XCTAssertEqual(loaded.state.kept.count, 1)
        XCTAssertTrue(loaded.state.pending.isEmpty)
        XCTAssertNil(loaded.state.lastScan)
        XCTAssertTrue(store.settings.automatic)
        // A state file from before the newer fields existed.
        try #"{"pinned": ["/a/x"]}"#.write(toFile: root + "/store/state.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(store.state.pinned, ["/a/x"])
        XCTAssertFalse(Store(directory: URL(fileURLWithPath: root + "/empty")).loadState().damaged)
    }
}

final class UpdateInstallTests: XCTestCase {
    var root: String!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = Paths.canonical(NSTemporaryDirectory()) + "/sweep-update-tests-" + UUID().uuidString
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    /// Something shaped like an app, with a version and a file that tells the copies apart.
    @discardableResult
    func app(_ path: String, version: String) throws -> URL {
        let url = URL(fileURLWithPath: root + "/" + path)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try version.write(to: url.appendingPathComponent("Contents/MacOS/Sweep"), atomically: true, encoding: .utf8)
        return url
    }

    func version(of url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/MacOS/Sweep"), encoding: .utf8)
    }

    func hidden(in folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: root + "/" + folder)) ?? []).filter { $0.hasPrefix(".") }
    }

    func testRequirementText() {
        XCTAssertEqual(UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.sweep"),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                       + " and certificate leaf[subject.OU] = \"NJTYRVLSA8\" and identifier \"gg.maben.sweep\" and notarized")
    }

    func testSwapPutsTheVerifiedCopyInPlace() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        try app("Apps/.Maben Sweep.update.app", version: "leftover")
        var verified: [URL] = [], discarded: [URL] = []
        try UpdateInstall.swap(target, with: new, verify: { verified.append($0); XCTAssertEqual(self.version(of: $0), "2.0") },
                               discard: { discarded.append($0); try? self.fm.removeItem(at: $0) })
        XCTAssertEqual(version(of: target), "2.0")
        XCTAssertEqual(verified.map(\.lastPathComponent), [".Maben Sweep.update.app"], "the copy next to the app is the one that is checked")
        XCTAssertEqual(verified.first?.deletingLastPathComponent().path, target.deletingLastPathComponent().path)
        XCTAssertEqual(discarded.map(\.lastPathComponent), [".Maben Sweep.old.app"])
        XCTAssertEqual(hidden(in: "Apps"), [])
    }

    func testACopyThatFailsTheCheckLeavesTheAppAlone() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        XCTAssertThrowsError(try UpdateInstall.swap(target, with: new, verify: { _ in throw UpdateInstall.Failure("not ours") },
                                                    discard: { _ in XCTFail("nothing to discard") })) {
            XCTAssertEqual($0 as? UpdateInstall.Failure, UpdateInstall.Failure("not ours"))
        }
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [], "the copy that failed is removed")
    }

    func testAFailedSecondRenamePutsTheOldAppBack() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        var moves = 0
        XCTAssertThrowsError(try UpdateInstall.swap(target, with: new, verify: { _ in }, move: { from, to in
            moves += 1
            if moves == 2 { throw CocoaError(.fileWriteNoPermission) }
            try self.fm.moveItem(at: from, to: to)
        }, discard: { _ in XCTFail("nothing to discard") }))
        XCTAssertEqual(moves, 3, "target aside, the failed move, target back")
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
    }

    func testAFailedFirstRenameLeavesTheAppAlone() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        XCTAssertThrowsError(try UpdateInstall.swap(target, with: new, verify: { _ in }, move: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                                                    discard: { _ in XCTFail("nothing to discard") }))
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
    }

    func testLeftoversAreRemoved() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        try app("Apps/.Maben Sweep.update.app", version: "x")
        try app("Apps/.Maben Sweep.old.app", version: "y")
        UpdateInstall.removeLeftovers(nextTo: target)
        XCTAssertEqual(hidden(in: "Apps"), [])
        XCTAssertEqual(version(of: target), "1.0")
    }

    // The administrator's command, run here as the current user in a temporary folder.

    func sh(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func command(target: URL, new: URL, version: String, token: String = "TOKEN") -> String {
        UpdateInstall.rootCommand(newApp: new.path, target: target.path,
                                  requirement: UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.sweep"),
                                  version: version, token: token)
    }

    /// The command with the two signature checks answered for it, to test everything around them.
    func passingChecks(_ command: String) -> String {
        command.replacingOccurrences(of: "/usr/bin/codesign", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/sbin/spctl", with: "/usr/bin/true")
    }

    func testRootCommandText() {
        let text = UpdateInstall.rootCommand(newApp: "/tmp/Update/Maben Sweep.app", target: "/Applications/Maben Sweep.app",
                                             requirement: UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.sweep"),
                                             version: "1.2", token: "TOKEN")
        // Line for line what Maben Awake runs, but for the second rename: there the old app stays
        // in the folder when it can't be put back, instead of being removed with it.
        XCTAssertEqual(text, """
        T='/Applications/Maben Sweep.app'
        D='/Applications/.Maben Sweep.update.TOKEN'
        S="$D"/'Maben Sweep.app'
        fail() { /bin/rm -rf "$D"; exit 1; }
        /bin/mkdir -m 700 "$D" || exit 1
        /usr/bin/ditto '/tmp/Update/Maben Sweep.app' "$S" || fail
        /usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail
        /bin/chmod -R ug-s "$S" || fail
        /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "NJTYRVLSA8" and identifier "gg.maben.sweep" and notarized' "$S" || fail
        /usr/sbin/spctl --assess --type execute "$S" || fail
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = '1.2' ] || fail
        /bin/mv "$T" "$D/old.app" || fail
        /bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }
        /bin/rm -rf "$D"
        exit 0
        """)
    }

    func testRootCommandQuotesEverythingItIsGiven() {
        let text = UpdateInstall.rootCommand(newApp: "/tmp/it's $(id) `id` \"x\"/New.app", target: "/Apps/O'Brien; id/Maben Sweep.app",
                                             requirement: "identifier \"a\" and 'b'", version: "1'; id; '", token: "t'; id")
        XCTAssertTrue(text.contains(#"/usr/bin/ditto '/tmp/it'\''s $(id) `id` "x"/New.app' "$S""#))
        XCTAssertTrue(text.contains(#"T='/Apps/O'\''Brien; id/Maben Sweep.app'"#))
        XCTAssertTrue(text.contains(#"D='/Apps/O'\''Brien; id/.Maben Sweep.update.t'\''; id'"#))
        XCTAssertTrue(text.contains(#"-R='identifier "a" and '\''b'\''' "$S""#))
        XCTAssertTrue(text.contains(#"= '1'\''; id; '\''' ]"#))
    }

    func testTheAppleScriptCantBeEndedByTheCommand() {
        let script = UpdateInstall.appleScript(running: "echo \"a\\b\"\nexit 0", prompt: "Install \"it\"")
        XCTAssertEqual(script, #"do shell script "echo \"a\\b\"\nexit 0" with prompt "Install \"it\"" with administrator privileges"#)
        XCTAssertFalse(script.contains("\n"), "a line break is written as \\n, inside the string")
        XCTAssertEqual(UpdateInstall.appleScriptString("a\tb\rc"), #""a\tb\rc""#)
    }

    func testRootCommandSwapsWhenEveryCheckPasses() throws {
        let target = try app("Apps/It's Maben Sweep.app", version: "1.0")
        let new = try app("down load/It's Maben Sweep.app", version: "2.0")
        XCTAssertEqual(sh(passingChecks(command(target: target, new: new, version: "2.0"))), 0)
        XCTAssertEqual(version(of: target), "2.0")
        XCTAssertEqual(hidden(in: "Apps"), [], "the staging folder is removed")
        XCTAssertEqual(version(of: new), "2.0", "the download is copied, not moved")
    }

    /// A copy made by root keeps the mode bits of the download, and the signature doesn't cover
    /// them, so a set-user-ID program in an update would become one that runs as the app's owner.
    func testRootCommandTakesAwaySetUserIDBits() throws {
        func bits(_ app: URL) -> mode_t {
            var info = stat()
            return stat(app.appendingPathComponent("Contents/MacOS/Sweep").path, &info) == 0 ? info.st_mode & (S_ISUID | S_ISGID) : 0
        }
        func install(_ name: String, edit: (String) -> String) throws -> URL {
            let target = try app(name + "/Maben Sweep.app", version: "1.0")
            let new = try app(name + "-download/Maben Sweep.app", version: "2.0")
            XCTAssertEqual(chmod(new.appendingPathComponent("Contents/MacOS/Sweep").path, 0o4755), 0)
            // Without root, `ditto` and `chown` drop the bit themselves. These stand-ins keep it, as root's do.
            let command = passingChecks(command(target: target, new: new, version: "2.0"))
                .replacingOccurrences(of: "/usr/bin/ditto", with: "/bin/cp -Rp").replacingOccurrences(of: "/usr/sbin/chown -R", with: "/usr/bin/true")
            XCTAssertEqual(sh(edit(command)), 0)
            XCTAssertEqual(version(of: target), "2.0")
            return target
        }
        let line = "/bin/chmod -R ug-s \"$S\" || fail\n"
        let without = try install("Unprotected") { command in
            XCTAssertTrue(command.contains(line))
            return command.replacingOccurrences(of: line, with: "")
        }
        try XCTSkipIf(bits(without) == 0, "The temporary folder doesn't keep set-user-ID bits.")
        XCTAssertEqual(bits(try install("Apps") { $0 }), 0)
    }

    func testRootCommandLeavesTheAppAloneWhenACheckFails() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        // The real checks: this made-up app isn't signed by anyone.
        XCTAssertNotEqual(sh(command(target: target, new: new, version: "2.0")), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
        // Signature answered, but another version than the release announced.
        XCTAssertNotEqual(sh(passingChecks(command(target: target, new: new, version: "2.1"))), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
        // Gatekeeper says no.
        let refused = command(target: target, new: new, version: "2.0").replacingOccurrences(of: "/usr/bin/codesign", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/sbin/spctl", with: "/usr/bin/false")
        XCTAssertNotEqual(sh(refused), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
        // The signature check says no.
        let unsigned = command(target: target, new: new, version: "2.0").replacingOccurrences(of: "/usr/bin/codesign", with: "/usr/bin/false")
            .replacingOccurrences(of: "/usr/sbin/spctl", with: "/usr/bin/true")
        XCTAssertNotEqual(sh(unsigned), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
        // No update to copy.
        XCTAssertNotEqual(sh(passingChecks(command(target: target, new: URL(fileURLWithPath: root + "/nope.app"), version: "2.0"))), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
    }

    func testRootCommandRefusesAStagingFolderThatAlreadyExists() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        // Someone made the folder first, with their own app in it.
        try app("Apps/.Maben Sweep.update.TOKEN/Maben Sweep.app", version: "planted")
        XCTAssertNotEqual(sh(passingChecks(command(target: target, new: new, version: "2.0"))), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [".Maben Sweep.update.TOKEN"], "a folder the command didn't make is not touched")
    }

    func testRootCommandPutsTheOldAppBackWhenTheSecondRenameFails() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        let rename = #"/bin/mv "$S" "$T" ||"#
        let passing = passingChecks(command(target: target, new: new, version: "2.0"))
        XCTAssertTrue(passing.contains(rename))
        XCTAssertNotEqual(sh(passing.replacingOccurrences(of: rename, with: #"/usr/bin/false "$S" "$T" ||"#)), 0)
        XCTAssertEqual(version(of: target), "1.0")
        XCTAssertEqual(hidden(in: "Apps"), [])
    }

    func testRootCommandKeepsTheOldAppWhenItCantBePutBack() throws {
        let target = try app("Apps/Maben Sweep.app", version: "1.0")
        let new = try app("download/Maben Sweep.app", version: "2.0")
        // Neither the new app can move in nor the old one back: the only copy of the app must survive.
        let stuck = passingChecks(command(target: target, new: new, version: "2.0"))
            .replacingOccurrences(of: #"/bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" ||"#, with: #"/usr/bin/false || { /usr/bin/false ||"#)
        XCTAssertNotEqual(sh(stuck), 0)
        XCTAssertEqual(version(of: URL(fileURLWithPath: root + "/Apps/.Maben Sweep.update.TOKEN/old.app")), "1.0")
    }

    /// The release that is installed on this Mac, if any, is what a real update looks like.
    func installedRelease() throws -> (app: URL, version: String) {
        let app = URL(fileURLWithPath: "/Applications/Maben Sweep.app")
        let requirement = UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.sweep")
        guard fm.fileExists(atPath: app.path),
              sh("/usr/bin/codesign --verify --deep --strict -R=\(Shell.quote(requirement)) \(Shell.quote(app.path))") == 0,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String else {
            throw XCTSkip("no notarized Maben Sweep in /Applications")
        }
        return (app, version)
    }

    /// The whole command with a real release and the real checks, as far as it goes without root.
    func testRootCommandInstallsARealRelease() throws {
        let release = try installedRelease()
        let target = try app("Apps/Maben Sweep.app", version: "0.1")
        func installed() -> String? {
            NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        }
        XCTAssertNotEqual(sh(command(target: target, new: release.app, version: release.version + ".1")), 0, "the right app under the wrong version")
        XCTAssertEqual(installed(), "0.1")
        XCTAssertEqual(hidden(in: "Apps"), [])
        // Signed by us, but not the app this is: the requirement names the bundle ID.
        let other = UpdateInstall.rootCommand(newApp: release.app.path, target: target.path,
                                              requirement: UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.other"),
                                              version: release.version, token: "TOKEN")
        XCTAssertNotEqual(sh(other), 0)
        XCTAssertEqual(installed(), "0.1")

        XCTAssertEqual(sh(command(target: target, new: release.app, version: release.version)), 0)
        XCTAssertEqual(installed(), release.version)
        XCTAssertEqual(hidden(in: "Apps"), [])
        let requirement = UpdateInstall.requirement(teamID: "NJTYRVLSA8", bundleID: "gg.maben.sweep")
        XCTAssertEqual(sh("/usr/bin/codesign --verify --deep --strict -R=\(Shell.quote(requirement)) \(Shell.quote(target.path))"), 0,
                       "what was installed is still the signed release")
    }

    func testTheReplacedVersionGetsAVisibleNameForTheTrash() {
        XCTAssertEqual(UpdateInstall.previousName(for: UpdateInstall.old(for: URL(fileURLWithPath: "/Applications/Maben Sweep.app"))),
                       "Maben Sweep (previous version).app")
    }

    // The feed.

    func feed(zip: String, page: String? = "https://github.com/maxbenschop/maben-sweep/releases/tag/v1.2") -> ReleaseFeed.Release? {
        var json: [String: Any] = ["tag_name": "v1.2", "body": "", "assets": [["name": "Maben-Sweep.zip", "browser_download_url": zip]]]
        json["html_url"] = page
        return ReleaseFeed.parse(try! JSONSerialization.data(withJSONObject: json))
    }

    let download = "https://github.com/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip"

    func testOnlyOurReleaseDownloadsAreAccepted() {
        XCTAssertNotNil(feed(zip: download))
        XCTAssertNotNil(feed(zip: download.replacingOccurrences(of: "github.com/", with: "github.com:443/")), "the port https uses anyway")
        for bad in ["http://github.com/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://github.com.evil.example/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://evil.example/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://github.com@evil.example/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://user@github.com/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://github.com:8443/maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://github.com/someone-else/maben-sweep/releases/download/v1.2/Maben-Sweep.zip",
                    "https://github.com/maxbenschop/maben-sweep/releases/download/../../../other/repo/x.zip",
                    "https://github.com/maxbenschop/maben-sweep/releases/download/%2e%2e/%2e%2e/x/Maben-Sweep.zip",
                    "https://github.com/maxbenschop/maben-sweep/releases/download/v1.2/..",
                    "https://github.com/maxbenschop/maben-sweep/archive/Maben-Sweep.zip",
                    "https://github.com/maxbenschop/maben-sweep-fork/releases/download/v1.2/Maben-Sweep.zip",
                    "file:///maxbenschop/maben-sweep/releases/download/v1.2/Maben-Sweep.zip"] {
            XCTAssertNil(feed(zip: bad), bad)
        }
    }

    func testOnlyAPageOnGitHubIsOpened() {
        XCTAssertEqual(feed(zip: download)?.page.absoluteString, "https://github.com/maxbenschop/maben-sweep/releases/tag/v1.2")
        // Anything else in the feed is replaced by this repository's releases page; the update itself is still fine.
        for page in ["http://github.com/maxbenschop/maben-sweep", "https://evil.example/x", "https://user@github.com/x", "https://github.com:8443/x",
                     "https://github.com/a/../../b", "file:///Applications/Calculator.app", "x-apple.systempreferences:", nil] {
            XCTAssertEqual(feed(zip: download, page: page)?.page.absoluteString, "https://github.com/maxbenschop/maben-sweep/releases", page ?? "no page")
        }
    }

    func testOnlyHttpsLinksStayLinksInTheNotes() {
        let notes = ReleaseFeed.attributedNotes("- See [the site](https://sweep.maben.gg), [a file](file:///etc/passwd), [plain](http://example.com) and [an app](x-apple.systempreferences:). **Bold** stays.")
        let links = notes.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://sweep.maben.gg"])
        let text = String(notes.characters)
        XCTAssertTrue(text.contains("a file") && text.contains("plain") && text.contains("an app"), "the words stay, as plain text")
        XCTAssertEqual(String(ReleaseFeed.attributedNotes("no markdown").characters), "no markdown")
    }
}
