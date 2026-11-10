import Foundation
import SweepCore

// sweep scan [--idle <days>] <folder>…   Prints what Maben Sweep would find. Removes nothing.
var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "scan" else {
    print("usage: sweep scan [--idle <days>] <folder>…\nPrints what Maben Sweep would find. Removes nothing.")
    exit(args.isEmpty ? 0 : 2)
}
args.removeFirst()
var settings = SweepSettings()
if let i = args.firstIndex(of: "--idle"), i + 1 < args.count, let days = Int(args[i + 1]) {
    settings.idleDays = days
    args.removeSubrange(i...i + 1)
}
let roots = args.isEmpty ? SweepSettings.defaultRoots() : args
let started = Date()
let (projects, _) = ProjectScanner(roots: roots).scan()
let state = SweepState()
var idleBytes: Int64 = 0, idleCount = 0

for project in projects.sorted(by: { $0.lastActivity < $1.lastActivity }) {
    let status = Planner.status(of: project, settings: settings, state: state)
    let label: String
    switch status {
    case .inUse: label = "in use"
    case .pinned: label = "pinned"
    case .nothingSafe: label = "asks"
    case .active(let left): label = "active, idle in \(left)d"
    case .idle(let days): label = "IDLE \(days)d"; idleBytes += project.safeBytes(kinds: settings.kinds); idleCount += 1
    case .scheduled: label = "scheduled"
    }
    print("\(Format.tilde(project.path))  [\(label)]  last: \(project.activitySource.label) \(Format.ago(project.lastActivity))")
    for artifact in project.artifacts {
        let tier = artifact.tier == .safe ? "safe" : "ask (\(artifact.reason ?? ""))"
        print("    \(Format.bytes(artifact.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(artifact.relativePath)  \(tier)")
    }
}
print("\n\(projects.count) projects with removable folders, scanned in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
print("\(idleCount) idle for \(settings.idleDays)+ days: \(Format.bytes(idleBytes)) could be freed automatically")
