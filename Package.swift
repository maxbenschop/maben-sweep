// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v13)],
    targets: [
        // Finding projects, deciding what is safe to remove, and removing it. No UI.
        .target(name: "SweepCore", path: "Sources/SweepCore"),
        // The menu bar app.
        .executableTarget(
            name: "Sweep",
            dependencies: ["SweepCore"],
            path: "Sources/Sweep",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        // `sweep scan <folder>`: prints what the app would find, removes nothing.
        .executableTarget(name: "SweepTool", dependencies: ["SweepCore"], path: "Sources/SweepTool"),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"], path: "Tests/SweepCoreTests"),
    ]
)
