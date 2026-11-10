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

/// One folder a toolchain creates and can recreate.
public struct ArtifactRule: Sendable {
    public let name: String
    public let kind: ArtifactKind
    /// The best tier this folder can get. Environments stay at `.ask`.
    public let tier: Tier
    /// If set, one of these must exist inside the folder, or it isn't what the name suggests.
    public let signature: [String]

    public init(_ name: String, _ kind: ArtifactKind, tier: Tier = .safe, signature: [String] = []) {
        self.name = name
        self.kind = kind
        self.tier = tier
        self.signature = signature
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
                      ArtifactRule(".vite", .cache), ArtifactRule(".cache", .cache),
                      ArtifactRule("dist", .build), ArtifactRule("build", .build), ArtifactRule("out", .build),
                      ArtifactRule("coverage", .cache), ArtifactRule("storybook-static", .build),
                  ]),
        Ecosystem("Rust", markers: ["Cargo.toml"], rebuild: "cargo build",
                  artifacts: [ArtifactRule("target", .build, signature: ["CACHEDIR.TAG", ".rustc_info.json"])]),
        Ecosystem("Swift", markers: ["Package.swift"], rebuild: "swift build",
                  artifacts: [ArtifactRule(".build", .build)]),
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
        Ecosystem("PHP", markers: ["composer.json"], lockfiles: [("composer.lock", "composer install")],
                  artifacts: [ArtifactRule("vendor", .dependencies)]),
        Ecosystem("Go", markers: ["go.mod"], lockfiles: [("go.sum", "go mod vendor")],
                  artifacts: [ArtifactRule("vendor", .dependencies)]),
        Ecosystem("Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                  rebuild: "./gradlew build",
                  artifacts: [ArtifactRule("build", .build), ArtifactRule(".gradle", .cache)]),
        Ecosystem("Maven", markers: ["pom.xml"], rebuild: "mvn package",
                  artifacts: [ArtifactRule("target", .build)]),
        Ecosystem(".NET", markers: ["*.csproj", "*.fsproj", "*.vbproj"], rebuild: "dotnet build",
                  artifacts: [ArtifactRule("bin", .build), ArtifactRule("obj", .build)]),
        Ecosystem("Flutter", markers: ["pubspec.yaml"], rebuild: "flutter pub get",
                  artifacts: [ArtifactRule(".dart_tool", .cache), ArtifactRule("build", .build)]),
        Ecosystem("Elixir", markers: ["mix.exs"], lockfiles: [("mix.lock", "mix deps.get")], rebuild: "mix compile",
                  artifacts: [ArtifactRule("deps", .dependencies), ArtifactRule("_build", .build)]),
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
