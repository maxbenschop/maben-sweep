import Foundation

/// What kind of folder it is. Settings can switch each kind on or off.
public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case dependencies, build, cache, environment

    public var label: String {
        switch self {
        case .dependencies: "Dependencies"
        case .build: "Build output"
        case .cache: "Caches"
        case .environment: "Environments"
        }
    }
}

/// How sure Sweep is that a folder can go.
public enum Tier: String, Codable, Sendable {
    /// Passed every check: cleaned automatically.
    case safe
    /// Regenerable, but one check is missing (no lockfile, not in git…): only on a click.
    case ask
    /// Never removed and not offered.
    case never
}

/// A sign that a folder with an everyday name (`dist`, `build`, `vendor`, `bin`…) really is what
/// its toolchain makes. The name, the file next to it and a `.gitignore` line are not enough for
/// those: a folder of your own can have all three.
public enum Evidence: Sendable {
    /// One of these is inside the folder. A name may hold one `*`, and `a/b` looks one folder down.
    case contains([String])
    /// The file next to the folder lists one of these tools (as `"tool":` in a `package.json`),
    /// and that tool writes to a folder with this name unless told otherwise.
    case uses(file: String, tools: [String])
    /// A build script or config file next to the folder names it as the place its output goes.
    case namedAsOutput
}

/// One folder a toolchain creates and can recreate.
public struct ArtifactRule: Sendable {
    public let name: String
    public let kind: ArtifactKind
    /// The best tier this folder can get. Environments stay at `.ask`.
    public let tier: Tier
    /// If set, one of these must exist inside the folder, or it isn't what the name suggests.
    public let signature: [String]
    /// If set, one of these signs must be there, or the folder asks first.
    public let evidence: [Evidence]
    /// Where the toolchain keeps git checkouts of its own inside the folder (`checkouts/*` for
    /// Swift packages). A checkout there that nobody worked in goes with the folder; a git
    /// repository anywhere else in it makes the folder ask first.
    public let checkouts: [String]

    public init(_ name: String, _ kind: ArtifactKind, tier: Tier = .safe, signature: [String] = [],
                evidence: [Evidence] = [], checkouts: [String] = []) {
        self.name = name
        self.kind = kind
        self.tier = tier
        self.signature = signature
        self.evidence = evidence
        self.checkouts = checkouts
    }
}

/// A toolchain: the file that proves a folder belongs to it, and the folders it creates.
public struct Ecosystem: Sendable {
    public let name: String
    /// One of these must sit next to the folder. `*.ext` matches by extension.
    public let markers: [String]
    /// Lockfile → the command that reinstalls from it. Dependencies without a lockfile are `.ask`.
    public let lockfiles: [(file: String, restore: String)]
    /// The command that brings back build output, if there is an obvious one.
    public let rebuild: String?
    public let artifacts: [ArtifactRule]

    public init(_ name: String, markers: [String], lockfiles: [(file: String, restore: String)] = [],
                rebuild: String? = nil, artifacts: [ArtifactRule]) {
        self.name = name
        self.markers = markers
        self.lockfiles = lockfiles
        self.rebuild = rebuild
        self.artifacts = artifacts
    }

    public func matches(_ names: Set<String>) -> Bool {
        markers.contains { marker in
            if marker.hasPrefix("*.") {
                let suffix = String(marker.dropFirst())
                return names.contains { $0.hasSuffix(suffix) }
            }
            return names.contains(marker)
        }
    }
}

/// Every folder Sweep knows how to remove. A folder that isn't listed here is never touched.
/// To support a new toolchain, add it here; the scanning and cleaning code doesn't change.
public enum Rules {
    /// Files a JavaScript build leaves behind and nobody writes by hand.
    private static let generated = ["*.js.map", "*.mjs.map", "*.cjs.map", "*.css.map", "*.d.ts", "*.d.mts", "*.d.cts",
                                    "*.tsbuildinfo", "*/*.js.map", "*/*.d.ts"]

    public static let ecosystems: [Ecosystem] = [
        Ecosystem("Node", markers: ["package.json"],
                  lockfiles: [("pnpm-lock.yaml", "pnpm install"), ("yarn.lock", "yarn install"),
                              ("bun.lock", "bun install"), ("bun.lockb", "bun install"),
                              ("package-lock.json", "npm install"), ("npm-shrinkwrap.json", "npm install")],
                  artifacts: [
                      ArtifactRule("node_modules", .dependencies),
                      ArtifactRule(".next", .build), ArtifactRule(".nuxt", .build), ArtifactRule(".output", .build),
                      ArtifactRule(".svelte-kit", .build), ArtifactRule(".astro", .cache), ArtifactRule(".expo", .cache),
                      ArtifactRule(".turbo", .cache), ArtifactRule(".parcel-cache", .cache), ArtifactRule(".angular", .cache),
                      ArtifactRule(".vite", .cache),
                      ArtifactRule(".cache", .cache, evidence: [
                          .contains(["gatsby-browser-entry.js", "redux", "caches/gatsby-*", "puppeteer"]),
                          .uses(file: "package.json", tools: ["gatsby", "parcel-bundler", "@remix-run/dev"]),
                          .namedAsOutput,
                      ]),
                      ArtifactRule("dist", .build, evidence: [
                          .contains(generated + [".vite", "_astro", "_nuxt", "_expo", "assets/index-*.js", "builder-debug.yml"]),
                          .uses(file: "package.json", tools: [
                              "vite", "webpack", "webpack-cli", "parcel", "tsup", "unbuild", "microbundle", "bunchee", "pkgroll",
                              "@vercel/ncc", "astro", "nuxt", "@angular/cli", "@angular-devkit/build-angular", "@nestjs/cli",
                              "@vue/cli-service", "@rsbuild/core", "@rspack/cli", "electron-builder", "expo",
                          ]),
                          .namedAsOutput,
                      ]),
                      ArtifactRule("build", .build, evidence: [
                          .contains(generated + ["asset-manifest.json", "static/js", "_app/immutable", "client/_app", "client/assets",
                                                 "config.gypi", "Release/*.node", "Debug/*.node"]),
                          .uses(file: "package.json", tools: [
                              "react-scripts", "@craco/craco", "react-app-rewired", "@docusaurus/core", "@remix-run/dev",
                              "@react-router/dev", "@sveltejs/kit", "preact-cli", "snowpack", "node-gyp",
                          ]),
                          .namedAsOutput,
                      ]),
                      ArtifactRule("out", .build, evidence: [
                          .contains(generated + ["_next", "make", "*-darwin-*", "*-win32-*", "*-linux-*"]),
                          .uses(file: "package.json", tools: ["next", "@electron-forge/cli", "electron-vite", "@vscode/vsce", "vsce", "@types/vscode"]),
                          .namedAsOutput,
                      ]),
                      // A coverage report always holds one of these, so the test runner in package.json isn't asked.
                      ArtifactRule("coverage", .cache, evidence: [
                          .contains(["lcov.info", "coverage-final.json", "coverage-summary.json", "clover.xml", "cobertura-coverage.xml",
                                     "lcov-report", "prettify.js", "block-navigation.js", "tmp/coverage-*.json", ".tmp/coverage-*.json"]),
                          .namedAsOutput,
                      ]),
                      ArtifactRule("storybook-static", .build),
                  ]),
        Ecosystem("Rust", markers: ["Cargo.toml"], rebuild: "cargo build",
                  artifacts: [ArtifactRule("target", .build, signature: ["CACHEDIR.TAG", ".rustc_info.json"])]),
        // SwiftPM clones each dependency into .build/checkouts and puts it back from Package.resolved.
        Ecosystem("Swift", markers: ["Package.swift"], rebuild: "swift build",
                  artifacts: [ArtifactRule(".build", .build, checkouts: ["checkouts/*"])]),
        Ecosystem("CocoaPods", markers: ["Podfile"], lockfiles: [("Podfile.lock", "pod install")],
                  artifacts: [ArtifactRule("Pods", .dependencies)]),
        Ecosystem("Python", markers: ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"],
                  lockfiles: [("uv.lock", "uv sync"), ("poetry.lock", "poetry install"), ("Pipfile.lock", "pipenv install"),
                              ("requirements.txt", "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt")],
                  artifacts: [
                      // An environment can hold packages that were installed by hand, so it always asks.
                      ArtifactRule(".venv", .environment, tier: .ask, signature: ["pyvenv.cfg"]),
                      ArtifactRule("venv", .environment, tier: .ask, signature: ["pyvenv.cfg"]),
                      ArtifactRule(".pytest_cache", .cache), ArtifactRule(".mypy_cache", .cache),
                      ArtifactRule(".ruff_cache", .cache), ArtifactRule(".tox", .cache),
                  ]),
        // Composer keeps a package installed "from source" as a git checkout in vendor/<maker>/<package>.
        Ecosystem("PHP", markers: ["composer.json"], lockfiles: [("composer.lock", "composer install")],
                  artifacts: [ArtifactRule("vendor", .dependencies, evidence: [.contains(["autoload.php", "composer/installed.json"])],
                                           checkouts: ["*/*"])]),
        Ecosystem("Go", markers: ["go.mod"], lockfiles: [("go.sum", "go mod vendor")],
                  artifacts: [ArtifactRule("vendor", .dependencies, evidence: [.contains(["modules.txt"])])]),
        Ecosystem("Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                  rebuild: "./gradlew build",
                  artifacts: [
                      ArtifactRule("build", .build, evidence: [.contains([
                          "classes/java", "classes/kotlin", "classes/groovy", "classes/scala", "intermediates", "generated/sources",
                          "generated/source", "tmp/compileJava", "tmp/compileKotlin", "tmp/kotlin-classes", "tmp/jar", "kotlin/compileKotlin",
                          "kotlin/sessions", "outputs/apk", "outputs/aar", "outputs/logs", "test-results", "reports/tests",
                          "reports/problems", "reports/configuration-cache", "resources/main", "libs/*.jar",
                      ])]),
                      ArtifactRule(".gradle", .cache),
                  ]),
        Ecosystem("Maven", markers: ["pom.xml"], rebuild: "mvn package",
                  artifacts: [ArtifactRule("target", .build, evidence: [.contains([
                      "classes", "test-classes", "maven-status", "maven-archiver", "generated-sources", "generated-test-sources",
                      "surefire-reports",
                  ])])]),
        Ecosystem(".NET", markers: ["*.csproj", "*.fsproj", "*.vbproj"], rebuild: "dotnet build",
                  artifacts: [
                      ArtifactRule("bin", .build, evidence: [.contains([
                          "Debug/*.dll", "Release/*.dll", "Debug/*.exe", "Release/*.exe", "Debug/*/*.dll", "Release/*/*.dll",
                          "Debug/*/*.deps.json", "Release/*/*.deps.json", "*/Debug/*/*.dll", "*/Release/*/*.dll",
                      ])]),
                      ArtifactRule("obj", .build, evidence: [.contains([
                          "project.assets.json", "project.nuget.cache", "*.nuget.g.props", "*.nuget.g.targets", "*.nuget.dgspec.json",
                          "Debug/*.FileListAbsolute.txt", "Release/*.FileListAbsolute.txt", "Debug/*/*.AssemblyInfo.cs", "Release/*/*.AssemblyInfo.cs",
                      ])]),
                  ]),
        Ecosystem("Flutter", markers: ["pubspec.yaml"], rebuild: "flutter pub get",
                  artifacts: [
                      ArtifactRule(".dart_tool", .cache),
                      ArtifactRule("build", .build, evidence: [.contains([
                          ".last_build_id", "flutter_assets", "app/intermediates", "app/outputs", "ios/Debug-iphonesimulator", "ios/Release-iphoneos",
                          "ios/iphoneos", "ios/iphonesimulator", "macos/Build", "web/flutter.js", "web/main.dart.js", "native_assets",
                          "unit_test_assets", "*.cache.dill.track.dill", "linux/x64", "linux/arm64", "windows/x64", "windows/runner",
                      ])]),
                  ]),
        // Mix keeps a dependency that comes from git as a checkout in deps/<name>.
        Ecosystem("Elixir", markers: ["mix.exs"], lockfiles: [("mix.lock", "mix deps.get")], rebuild: "mix compile",
                  artifacts: [
                      ArtifactRule("deps", .dependencies, evidence: [.contains(["*/mix.exs", "*/rebar.config", "*/.hex", "*/erlang.mk"])],
                                   checkouts: ["*"]),
                      ArtifactRule("_build", .build),
                  ]),
        Ecosystem("Zig", markers: ["build.zig"], rebuild: "zig build",
                  artifacts: [ArtifactRule("zig-cache", .cache), ArtifactRule(".zig-cache", .cache), ArtifactRule("zig-out", .build)]),
        Ecosystem("Haskell", markers: ["stack.yaml"], rebuild: "stack build",
                  artifacts: [ArtifactRule(".stack-work", .build)]),
    ]

    /// Folders that are never worth walking into while looking for projects.
    public static let neverDescend: Set<String> = [
        "node_modules", "bower_components", "Pods", ".venv", "venv", "site-packages", "__pycache__",
        "DerivedData", "Library", "Applications", "Music", "Movies", "Pictures", "Photos Library.photoslibrary",
    ]

    /// Folders with these extensions are documents or bundles, not places projects live.
    public static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "xcodeproj", "xcworkspace", "xcassets", "photoslibrary", "lproj",
        "playground", "sparsebundle", "dmg", "pkg", "plugin", "kext", "xcarchive", "docset",
    ]

    /// Every artifact name, for skipping them when looking at source files.
    public static let allArtifactNames: Set<String> = Set(ecosystems.flatMap { $0.artifacts.map(\.name) })
}
