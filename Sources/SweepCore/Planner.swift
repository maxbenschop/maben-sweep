import Foundation

/// Where a project stands, for the list.
public enum ProjectStatus: Equatable, Sendable {
    /// A program is running from it.
    case inUse
    /// Marked "never clean".
    case pinned
    /// Nothing in it that automatic cleanup may remove.
    case nothingSafe
    /// Worked on recently; idle in this many days.
    case active(daysLeft: Int)
    /// Idle long enough.
    case idle(days: Int)
    /// Warned about; cleaned on this date.
    case scheduled(Date)
}

/// What an automatic run should do.
public struct Plan: Equatable, Sendable {
    /// Idle for the first time: warn, and clean after the warning period.
    public var warn: [String] = []
    /// The warning period is over (or there is none): clean now.
    public var clean: [String] = []
    /// Were scheduled, but got used, pinned or emptied since: forget the schedule.
    public var drop: [String] = []
}

/// The rules for when a project gets cleaned. No file access; only dates and settings.
public enum Planner {
    public static func threshold(for project: Project, settings: SweepSettings, state: SweepState) -> Int {
        state.customIdleDays[project.path] ?? settings.idleDays
    }

    /// Last activity, where "Keep for now" counts as activity.
    public static func effectiveActivity(of project: Project, state: SweepState) -> Date {
        max(project.lastActivity, state.kept[project.path] ?? .distantPast)
    }

    public static func status(of project: Project, settings: SweepSettings, state: SweepState, now: Date = Date()) -> ProjectStatus {
        if state.pinned.contains(project.path) { return .pinned }
        if project.inUse { return .inUse }
        if project.safeBytes(kinds: settings.kinds) <= 0 { return .nothingSafe }
        let idle = Format.days(since: effectiveActivity(of: project, state: state), now: now)
        let limit = threshold(for: project, settings: settings, state: state)
        if idle < limit { return .active(daysLeft: limit - idle) }
        if settings.automatic, let date = state.pending[project.path] { return .scheduled(date) }
        return .idle(days: idle)
    }

    /// Idle, not pinned, not in use, and with something safe to remove.
    public static func isDue(_ project: Project, settings: SweepSettings, state: SweepState, now: Date = Date()) -> Bool {
        switch status(of: project, settings: settings, state: state, now: now) {
        case .idle, .scheduled: true
        default: false
        }
    }

    public static func plan(projects: [Project], settings: SweepSettings, state: SweepState, now: Date = Date()) -> Plan {
        var plan = Plan()
        guard settings.automatic else {
            plan.drop = state.pending.keys.sorted()
            return plan
        }
        let byPath = Dictionary(projects.map { ($0.path, $0) }) { first, _ in first }
        for project in projects where isDue(project, settings: settings, state: state, now: now) {
            if let date = state.pending[project.path] {
                if date <= now { plan.clean.append(project.path) }
            } else if settings.warnDays == 0 {
                plan.clean.append(project.path)
            } else {
                plan.warn.append(project.path)
            }
        }
        for path in state.pending.keys.sorted() {
            guard let project = byPath[path], isDue(project, settings: settings, state: state, now: now) else {
                plan.drop.append(path)
                continue
            }
        }
        return plan
    }
}
