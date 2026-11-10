import AppKit
import SwiftUI
import SweepCore

enum Pane: String, CaseIterable, Identifiable {
    case projects, caches, history, cleanup, folders, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .caches: "Caches"
        case .history: "History"
        case .cleanup: "Cleanup"
        case .folders: "Folders"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .projects: "Folders that come back with one command, per project."
        case .caches: "Shared caches of your tools. Cleaned only when you click."
        case .history: "What Sweep removed, and how to bring it back."
        case .cleanup: "When Sweep cleans by itself, and what it may remove."
        case .folders: "Where Sweep looks for projects."
        case .about: ""
        }
    }

    var symbol: String {
        switch self {
        case .projects: "folder.fill"
        case .caches: "internaldrive.fill"
        case .history: "clock.arrow.circlepath"
        case .cleanup: "gearshape.fill"
        case .folders: "magnifyingglass"
        case .about: "info.circle.fill"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .projects: ProjectsPane()
        case .caches: CachesPane()
        case .history: HistoryPane()
        case .cleanup: CleanupPane()
        case .folders: FoldersPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Projects

struct ProjectsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: Navigation
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var expanded: Set<String> = ProjectsPane.initiallyExpanded
    @State private var confirmAll = false
    /// Rows that start opened; only set for screenshots.
    static var initiallyExpanded: Set<String> = []

    enum Filter: String, CaseIterable { case all = "All", idle = "Idle" }

    /// Idle first, then the rest; biggest first inside each group.
    private var rows: [Project] {
        let query = search.trimmingCharacters(in: .whitespaces)
        func rank(_ p: Project) -> Int {
            switch model.status(of: p) {
            case .scheduled: 0
            case .idle: 1
            case .active: 2
            case .inUse: 3
            case .nothingSafe: 4
            case .pinned: 5
            }
        }
        return model.projects
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
            .filter { filter == .all || rank($0) <= 1 }
            .sorted { a, b in
                let ra = rank(a), rb = rank(b)
                return ra != rb ? ra < rb : a.totalBytes > b.totalBytes
            }
    }

    var body: some View {
        MBPage(title: "Projects", subtitle: Pane.projects.subtitle) {
            SummaryCard(confirmAll: $confirmAll)

            if let notice = model.notice {
                Notice(text: notice) { model.notice = nil }
            }

            if !model.hasScanned && !model.scanning {
                Welcome()
            } else {
                if model.hasScanned, !model.settings.automatic, !model.dueProjects.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(MB.accent)
                        Text("Sweep only shows what could go. Turn on automatic cleanup to have idle projects cleaned for you.")
                            .font(.system(size: 12.5)).foregroundStyle(MB.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Set up") { navigation.pane = .cleanup }.buttonStyle(.mbQuiet)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.accent.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.accent.opacity(0.25)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        MBSearchField(placeholder: "Search projects", text: $search)
                        MBSegmented(options: Filter.allCases, selection: $filter) { $0.rawValue }
                    }
                    MBSection {
                        if rows.isEmpty {
                            Text(emptyText)
                                .font(.system(size: 13))
                                .foregroundStyle(MB.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 26)
                        }
                        ForEach(rows) { project in
                            ProjectRow(project: project, expanded: expanded.contains(project.path)) {
                                if !expanded.insert(project.path).inserted { expanded.remove(project.path) }
                            }
                        }
                    }
                    if !model.projects.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                            Text("Anything git tracks, .env files, databases and uploads are never listed here.")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(MB.dim)
                    }
                }
            }
        }
        .confirmationDialog("Clean \(model.dueProjects.count) idle \(model.dueProjects.count == 1 ? "project" : "projects")?",
                            isPresented: $confirmAll) {
            Button("Clean and free \(Format.bytes(model.dueBytes))") { model.cleanAllDue() }
        } message: {
            Text("Removes dependencies, build output and caches from projects idle for \(model.settings.idleDays) days or more. "
                 + (model.settings.removal == .trash ? "They go to the Trash." : "They are deleted right away.")
                 + " History shows the command that brings each one back.")
        }
    }

    private var emptyText: String {
        if model.scanning { return "Looking for projects…" }
        if !search.isEmpty { return "No projects match \u{201C}\(search)\u{201D}" }
        if filter == .idle { return "No idle projects. Nothing to clean." }
        return model.settings.roots.isEmpty ? "Add a folder under Folders to get started." : "No projects with removable folders found."
    }
}

/// The total at the top of Projects, with Scan and Clean.
private struct SummaryCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var confirmAll: Bool

    var body: some View {
        let due = !model.dueProjects.isEmpty
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(due ? AnyShapeStyle(MB.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.1)))
                BroomGlyph(size: 18).foregroundStyle(due ? Color.black : MB.muted)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MB.text)
                Text(model.scanning ? (model.scanningPath.map { "Scanning \(Format.tilde($0))" } ?? "Scanning…") : model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(MB.muted)
                    .lineLimit(1)
                    .truncationMode(model.scanning ? .middle : .tail)
            }
            Spacer(minLength: 8)
            if model.scanning {
                ProgressView().controlSize(.small)
            } else if model.hasScanned {
                Button("Scan") { model.scan() }.buttonStyle(.mbQuiet).help("Look at your projects again")
                if due {
                    Button("Clean idle") { confirmAll = true }.buttonStyle(.mbPrimary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: MB.radius, style: .continuous)
                .fill(LinearGradient(colors: [MB.accent.opacity(due ? 0.14 : 0.04), MB.card],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous)
            .strokeBorder(due ? MB.accent.opacity(0.3) : MB.line))
    }
}

/// Shown until the first scan.
private struct Welcome: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Maben Sweep")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(MB.text)
            VStack(alignment: .leading, spacing: 12) {
                step("magnifyingglass", "Sweep looks for projects in \(folders).")
                step("eye.fill", "The first scan only shows what could go. Nothing is removed.")
                step("checkmark.shield.fill", "It only ever lists folders that come back with one command, like node_modules.")
            }
            HStack(spacing: 8) {
                Button("Scan my projects") { model.scan() }.buttonStyle(.mbPrimary).disabled(model.settings.roots.isEmpty)
                Button("Choose folders") { navigation.pane = .folders }.buttonStyle(.mbQuiet)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.line))
    }

    private var folders: String {
        let names = model.settings.roots.map { Format.tilde($0) }
        switch names.count {
        case 0: return "the folders you choose"
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.accent).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var confirm = false

    var body: some View {
        let status = model.status(of: project)
        let busy = model.busy.contains(project.path)
        let safe = project.safeBytes(kinds: model.settings.kinds)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MB.dim)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(project.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(MB.text)
                                    .lineLimit(1)
                                if let first = project.ecosystems.first { Tag(text: first) }
                                if project.ecosystems.count > 1 { Tag(text: "+\(project.ecosystems.count - 1)") }
                            }
                            Text(detail(status))
                                .font(.system(size: 12))
                                .foregroundStyle(MB.dim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(project.name), \(detail(status))")

                // What Clean would free; for a project that only asks, everything in it.
                Text(Format.bytes(safe > 0 ? safe : project.totalBytes))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(safe > 0 ? MB.text : MB.dim)
                StatusPill(status: status)
                    .help(pillHelp(status))
                if busy {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Clean") { confirm = true }
                        .buttonStyle(isIdle(status) ? MBButtonStyle(kind: .primary) : MBButtonStyle(kind: .quiet))
                        .disabled(safe <= 0 || status == .inUse)
                        .help(safe <= 0 ? "Nothing here is safe to remove without asking. Open the row to remove a folder yourself."
                              : status == .inUse ? "A program is running in this project." : "Remove \(Format.bytes(safe)) now")
                }
                ProjectMenu(project: project, status: status)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background(hovering ? Color.white.opacity(0.025) : .clear)
            .onHover { hovering = $0 }

            if expanded { ProjectDetail(project: project) }
        }
        .confirmationDialog("Clean \(project.name)?", isPresented: $confirm) {
            Button("Remove \(Format.bytes(safe))") { model.clean(project) }
        } message: {
            Text(confirmText)
        }
    }

    private func isIdle(_ status: ProjectStatus) -> Bool {
        switch status {
        case .idle, .scheduled: true
        default: false
        }
    }

    private func detail(_ status: ProjectStatus) -> String {
        if status == .inUse { return "A program is running here" }
        return "Last used \(Format.ago(Planner.effectiveActivity(of: project, state: model.state)))"
    }

    private func pillHelp(_ status: ProjectStatus) -> String {
        switch status {
        case .active(let left): "Counts as idle in \(left) \(left == 1 ? "day" : "days")."
        case .scheduled(let date): "Cleaned automatically \(AppModel.day(date)), unless you use it before then."
        case .inUse: "Never cleaned while a program runs in it."
        case .pinned: "You chose to never clean this project."
        case .nothingSafe: "Nothing here is removed without asking: \(project.askArtifacts.first?.reason?.lowercased() ?? "open the row to see why")."
        case .idle(let days): "Not used for \(days) days."
        }
    }

    private var confirmText: String {
        let items = project.safeArtifacts(kinds: model.settings.kinds)
        let names = items.map(\.relativePath).prefix(4).joined(separator: ", ") + (items.count > 4 ? " and \(items.count - 4) more" : "")
        let back = items.compactMap(\.restore).first.map { " Bring them back with \($0)." } ?? " They come back the next time you build."
        return "Removes \(names)." + back
    }
}

private struct StatusPill: View {
    let status: ProjectStatus

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .scheduled(let date): (AppModel.day(date).replacingOccurrences(of: "on ", with: "").capitalized, MB.accent)
        case .idle(let days): ("Idle \(days)d", MB.orange)
        case .active: ("Active", MB.muted)
        case .inUse: ("In use", MB.muted)
        case .pinned: ("Kept", MB.muted)
        case .nothingSafe: ("Asks", MB.muted)
        }
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .lineLimit(1)
            .frame(width: 78, height: 20)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Keep, never clean, a project's own idle time, and Show in Finder.
private struct ProjectMenu: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let status: ProjectStatus

    var body: some View {
        let pinned = model.state.pinned.contains(project.path)
        let custom = model.state.customIdleDays[project.path]
        Menu {
            Button("Keep for now") { model.keep(project) }
                .disabled(pinned)
            Button(pinned ? "Allow cleaning again" : "Never clean this project") { model.setPinned(project, !pinned) }
            Menu("Idle after") {
                Button { model.setIdleDays(project, nil) } label: {
                    Label("Default (\(model.settings.idleDays) days)", systemImage: custom == nil ? "checkmark" : "")
                }
                ForEach(SweepSettings.idleChoices + [365], id: \.self) { days in
                    Button { model.setIdleDays(project, days) } label: {
                        Label("\(days) days", systemImage: custom == days ? "checkmark" : "")
                    }
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MB.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// The folders in one project, with why each is safe or asks first.
private struct ProjectDetail: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    @State private var asking: Artifact?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(project.artifacts) { artifact in
                let off = artifact.tier == .safe && !model.settings.kinds.contains(artifact.kind)
                HStack(spacing: 10) {
                    Image(systemName: artifact.tier == .safe && !off ? "checkmark.circle.fill" : "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(artifact.tier == .safe && !off ? MB.accent : MB.orange)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.relativePath)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MB.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(off ? "\(artifact.kind.label) are switched off under Cleanup"
                             : artifact.tier == .safe ? "\(artifact.kind.label) · safe to remove" + (artifact.restore.map { " · back with \($0)" } ?? "")
                             : "Asks first: \((artifact.reason ?? "").prefix(1).lowercased() + (artifact.reason ?? "").dropFirst())")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MB.dim)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(Format.bytes(artifact.bytes))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(MB.muted)
                    if artifact.tier == .ask || off {
                        Button("Remove") { asking = artifact }
                            .buttonStyle(.mbQuiet)
                            .disabled(model.busy.contains(project.path) || project.inUse)
                    }
                }
                .padding(.vertical, 7)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10.5))
                Text(Format.tilde(project.path)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(MB.dim)
            .padding(.top, 6)
        }
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Color.white.opacity(0.018))
        .confirmationDialog("Remove \(asking?.relativePath ?? "")?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Remove \(Format.bytes(asking?.bytes ?? 0))", role: .destructive) {
                if let artifact = asking { model.clean(project, artifacts: [artifact], allowAsk: true) }
            }
        } message: {
            Text((asking?.reason.map { $0 + ". " } ?? "")
                 + (asking?.restore.map { "Bring it back with \($0)." } ?? "Sweep doesn't know a command that brings this back exactly as it was."))
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MB.muted)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

struct Notice: View {
    let text: String
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MB.orange)
            Text(text).font(.system(size: 12.5)).foregroundStyle(MB.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(MB.muted).help("Dismiss")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.orange.opacity(0.3)))
    }
}

// MARK: - Caches

struct CachesPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var asking: GlobalCache?

    var body: some View {
        MBPage(title: "Caches", subtitle: Pane.caches.subtitle) {
            MBSection(footer: "These fill up again as you work, so cleaning them is most useful when you're short on space. Sweep never cleans them by itself.") {
                if model.caches.isEmpty {
                    HStack(spacing: 10) {
                        if model.cachesLoading { ProgressView().controlSize(.small) }
                        Text(model.cachesLoading ? "Measuring caches…" : "No caches found on this Mac.")
                            .font(.system(size: 13)).foregroundStyle(MB.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }
                ForEach(model.caches) { cache in
                    MBRow(icon: "internaldrive", title: cache.name, detail: cache.detail) {
                        Text(Format.bytes(cache.bytes))
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(MB.text)
                        if model.busy.contains(cache.path) {
                            ProgressView().controlSize(.small).frame(width: 52)
                        } else {
                            Button("Clean") { asking = cache }.buttonStyle(.mbQuiet)
                        }
                    }
                }
            }
            if !model.caches.isEmpty {
                HStack {
                    Text("\(Format.bytes(model.caches.reduce(0) { $0 + $1.bytes })) in total")
                        .font(.system(size: 12)).foregroundStyle(MB.dim)
                    Spacer()
                    Button("Measure again") { model.loadCaches() }.buttonStyle(.mbQuiet).disabled(model.cachesLoading)
                }
            }
        }
        .onAppear { if model.caches.isEmpty { model.loadCaches() } }
        .confirmationDialog("Clean \(asking?.name ?? "")?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Remove \(Format.bytes(asking?.bytes ?? 0))") { if let cache = asking { model.empty(cache) } }
        } message: {
            Text(asking?.detail ?? "")
        }
    }
}

// MARK: - History

struct HistoryPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        MBPage(title: "History", subtitle: Pane.history.subtitle) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1))
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 17)).foregroundStyle(MB.accent)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Format.bytes(model.totalFreed)) freed")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                    Text(model.history.isEmpty ? "Nothing cleaned yet."
                         : "\(model.history.count) \(model.history.count == 1 ? "cleanup" : "cleanups") so far.")
                        .font(.system(size: 12)).foregroundStyle(MB.muted)
                }
                Spacer()
                if let free = model.freeSpace {
                    Text("\(Format.bytes(free)) free on this Mac")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(MB.dim)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.line))

            if !model.history.isEmpty {
                MBSection(footer: "Restore opens Terminal and runs the command there, so you can see what it does. Build output has no command: it comes back the next time you build.") {
                    ForEach(model.history) { entry in HistoryRow(entry: entry) }
                }
                HStack {
                    Spacer()
                    Button("Clear history") { confirmClear = true }.buttonStyle(.mbQuiet)
                }
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Only the list is cleared. The restore commands are gone with it.")
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: HistoryEntry
    @State private var copied = false

    var body: some View {
        let commands = entry.restoreCommands
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.projectName).font(.system(size: 13, weight: .medium)).foregroundStyle(MB.text).lineLimit(1)
                    if entry.automatic { Tag(text: "Automatic") }
                    if entry.removal == .trash { Tag(text: "In the Trash") }
                }
                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.items.map(\.relativePath).joined(separator: ", "))")
                    .font(.system(size: 12)).foregroundStyle(MB.dim).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(entry.bytes))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(MB.text)
            if !commands.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? MB.accent : MB.muted)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Copy the restore command")
                Button("Restore") { model.restore(entry) }
                    .buttonStyle(.mbQuiet)
                    .disabled(!FileManager.default.fileExists(atPath: entry.projectPath))
                    .help(commands.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Cleanup

struct CleanupPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MBPage(title: "Cleanup", subtitle: Pane.cleanup.subtitle) {
            if model.settings.automatic, model.settings.warnDays > 0, model.notificationsDenied {
                Notice(text: "Notifications are off for Maben Sweep, so the warning before a cleanup can't be shown. Turn them on in System Settings › Notifications. The date of the next cleanup is always shown under Projects.")
            }
            MBSection(title: "Automatic",
                      footer: model.settings.automatic
                        ? "Sweep looks once a day. A project that has been idle long enough gets a warning first, then is cleaned."
                        : "Off: Sweep only shows what could go. You clean by hand under Projects.") {
                MBRow(icon: "wand.and.stars", tint: model.settings.automatic ? MB.accent : MB.text,
                      title: "Clean idle projects automatically") {
                    MBToggle(isOn: $model.settings.automatic)
                }
                MBRow(icon: "moon.zzz.fill", title: "Idle after",
                      info: "Counted from the last commit on any branch, the last changed file, or the last AI agent session in the project, whichever is newest.") {
                    MBSegmented(options: SweepSettings.idleChoices, selection: $model.settings.idleDays) { "\($0) days" }
                }
                MBRow(icon: "bell.fill", title: "Warn me before cleaning",
                      info: "A notification with a Keep button. Opening the project or working in it during this time cancels the cleanup.") {
                    MBSegmented(options: SweepSettings.warnChoices, selection: $model.settings.warnDays) {
                        $0 == 0 ? "No" : $0 == 1 ? "1 day" : "\($0) days"
                    }
                    .disabled(!model.settings.automatic)
                }
                MBRow(icon: "powerplug.fill", title: "Only while on power",
                      detail: "Scanning and cleaning wait for the charger.") {
                    MBToggle(isOn: $model.settings.onlyOnPower)
                }
            }

            MBSection(title: "What may be removed",
                      footer: "Python environments are never removed automatically: they can hold packages you installed by hand. They show up under Projects with a Remove button.") {
                kind(.dependencies, "shippingbox.fill", "node_modules, Pods, vendor. Needs a lockfile.")
                kind(.build, "hammer.fill", ".next, dist, build, target, .build")
                kind(.cache, "archivebox.fill", ".turbo, .gradle, .pytest_cache, coverage")
            }

            MBSection(title: "How") {
                MBRow(icon: "trash.fill", title: "Move to the Trash instead of deleting",
                      detail: model.settings.removal == .trash ? "The space is free once you empty the Trash."
                                                               : "Off: removed right away, so the space is free at once.") {
                    MBToggle(isOn: Binding(get: { model.settings.removal == .trash },
                                           set: { model.settings.removal = $0 ? .trash : .delete }))
                }
                MBRow(icon: "externaldrive.badge.exclamationmark", title: "Warn when disk space is low",
                      info: "A notification when less than this is free, and only if idle projects can free space.") {
                    MBSegmented(options: SweepSettings.lowDiskChoices, selection: $model.settings.lowDiskGB) { "\($0) GB" }
                        .disabled(!model.settings.lowDiskAlert)
                    MBToggle(isOn: $model.settings.lowDiskAlert)
                }
            }

            MBSection(title: "A folder is only removed when") {
                check("Its name is known and the file that proves it sits next to it", "node_modules only counts beside a package.json.")
                check("Git ignores it and tracks nothing inside it", "A committed dist or build folder is never touched.")
                check("It can be rebuilt the same way", "Dependencies need a lockfile.")
                check("It is a real folder inside the project", "Links to other places are never followed.")
                check("Nothing is running in the project", "A dev server or an agent keeps it safe.")
            }

            MBSection(title: "Startup") {
                MBRow(icon: "power", title: "Open at login",
                      info: "Sweep needs to be running to clean automatically. It sits in the menu bar and does nothing between scans.") {
                    MBToggle(isOn: $model.launchAtLogin).disabled(!isBundled)
                }
            }
        }
        .onAppear { refreshNotifications() }
        .onChange(of: model.settings.automatic) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { refreshNotifications() }
        }
    }

    private func refreshNotifications() {
        Notifier.checkDenied { model.notificationsDenied = $0 }
    }

    private func kind(_ kind: ArtifactKind, _ symbol: String, _ detail: String) -> some View {
        MBRow(icon: symbol, title: kind.label, detail: detail) {
            MBToggle(isOn: Binding(
                get: { model.settings.kinds.contains(kind) },
                set: { if $0 { model.settings.kinds.insert(kind) } else { model.settings.kinds.remove(kind) } }))
        }
    }

    private func check(_ title: String, _ detail: String) -> some View {
        MBRow(icon: "checkmark", tint: MB.accent, title: title, detail: detail)
    }
}

// MARK: - Folders

struct FoldersPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MBPage(title: "Folders", subtitle: Pane.folders.subtitle) {
            MBSection(title: "Sweep looks in",
                      footer: "Everything below these folders is searched for projects. macOS may ask once whether Sweep may read a folder.") {
                if model.settings.roots.isEmpty {
                    empty("No folders yet. Add the folder that holds your projects.")
                }
                ForEach(model.settings.roots, id: \.self) { path in
                    let missing = model.live && !FileManager.default.fileExists(atPath: path)
                    MBRow(icon: "folder.fill", title: Format.tilde(path),
                          detail: missing ? "This folder no longer exists." : count(under: path)) {
                        Button("Remove") { model.removeRoot(path) }.buttonStyle(.mbQuiet)
                    }
                }
                addRow("Add a folder") { model.addRoot($0) }
            }

            MBSection(title: "Never look in", footer: "Projects in these folders are skipped completely.") {
                ForEach(model.settings.excluded, id: \.self) { path in
                    MBRow(icon: "eye.slash.fill", title: Format.tilde(path)) {
                        Button("Remove") { model.removeExcluded(path) }.buttonStyle(.mbQuiet)
                    }
                }
                addRow("Skip a folder") { model.addExcluded($0) }
            }

            if !model.state.pinned.isEmpty {
                MBSection(title: "Never cleaned", footer: "Set per project under Projects, with the \u{2026} button.") {
                    ForEach(model.state.pinned.sorted(), id: \.self) { path in
                        MBRow(icon: "pin.fill", title: (path as NSString).lastPathComponent, detail: Format.tilde(path)) {
                            Button("Allow") { model.state.pinned.remove(path) }.buttonStyle(.mbQuiet)
                        }
                    }
                }
            }
        }
    }

    private func count(under root: String) -> String {
        let n = model.projects.filter { $0.path == root || $0.path.hasPrefix(root + "/") }.count
        return model.hasScanned ? "\(n) \(n == 1 ? "project" : "projects") with removable folders" : "Not scanned yet"
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(MB.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private func addRow(_ title: String, add: @escaping (String) -> Void) -> some View {
        HStack {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.prompt = "Choose"
                if panel.runModal() == .OK { panel.urls.forEach { add($0.path) } }
            } label: {
                Label(title, systemImage: "plus")
            }
            .buttonStyle(.mbQuiet)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - About

struct AboutPane: View {
    private var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: MB.accent.opacity(0.25), radius: 24, y: 8)
                MBWordmark(size: 22).padding(.top, 18)
                Text("Version \(short)")
                    .textSelection(.enabled)
                    .font(.system(size: 12))
                    .foregroundStyle(MB.dim)
                    .padding(.top, 8)

                UpdatesSection()
                    .frame(width: 460)
                    .padding(.top, 24)

                if !WhatsNew.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New in this version").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.dim)
                        ForEach(WhatsNew.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(MB.accent).frame(width: 5, height: 5).padding(.top, 6)
                                Text(item).font(.system(size: 12.5)).foregroundStyle(MB.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)
                    .frame(width: 400, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).fill(MB.card))
                    .overlay(RoundedRectangle(cornerRadius: MB.radius, style: .continuous).strokeBorder(MB.line))
                    .padding(.top, 24)
                }

                HStack(spacing: 8) {
                    Link(destination: URL(string: "https://sweep.maben.gg")!) { Text("Website") }.buttonStyle(.mbPrimary)
                    Link(destination: URL(string: "https://sweep.maben.gg/changelog/")!) { Text("Changelog") }.buttonStyle(.mbQuiet)
                    Link(destination: URL(string: "https://github.com/maxbenschop/maben-sweep")!) { Text("GitHub") }.buttonStyle(.mbQuiet)
                    Link(destination: URL(string: "https://sweep.maben.gg/support/")!) { Text("Support") }.buttonStyle(.mbQuiet)
                }
                .padding(.top, 20)
                Text("© 2026 Maben · MIT licence")
                    .font(.system(size: 11))
                    .foregroundStyle(MB.dim)
                    .padding(.top, 22)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
            .padding(.bottom, 32)
        }
    }
}

/// Version, the Update button, and the two automatic-update switches (as in Maben Awake's Settings).
struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared
    @State private var showNotes = false

    var body: some View {
        MBSection(title: "Updates") {
            MBRow(icon: updater.available == nil ? "checkmark.seal.fill" : "arrow.down.circle.fill",
                  tint: updater.available == nil ? MB.text : MB.accent,
                  title: title, detail: detail) {
                trailing
            }
            MBRow(icon: "arrow.triangle.2.circlepath", title: "Check for updates automatically",
                  info: "Asks GitHub for the latest release at start and every 6 hours. It's the only time Maben Sweep connects to the internet.") {
                MBToggle(isOn: $updater.autoCheck)
            }
            MBRow(icon: "square.and.arrow.down.fill", title: "Install updates automatically",
                  info: "Only while no scan or cleanup is running. Every update is checked for the Maben signature and Apple's notarization before it's installed.") {
                MBToggle(isOn: $updater.autoInstall).disabled(!updater.autoCheck)
            }
        }
    }

    private var title: String {
        if let r = updater.available { return "Version \(r.version) is available" }
        return isBundled ? "Maben Sweep \(updater.currentVersion)" : "Development copy"
    }

    private var detail: String {
        switch updater.state {
        case .idle: return isBundled ? "Not checked yet." : "Updates only work in the installed app."
        case .checking: return "Checking GitHub…"
        case .upToDate(let date): return "Up to date. Checked \(date.formatted(.relative(presentation: .named)))."
        case .available: return updater.canInstall ? "Installs in a few seconds, then restarts." : "Move the app to Applications to update."
        case .downloading(_, let p): return "Downloading… \(Int(p * 100))%"
        case .installing: return "Installing. Maben Sweep restarts in a moment."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var trailing: some View {
        switch updater.state {
        case .available(let release):
            Button("What's new") { showNotes.toggle() }
                .buttonStyle(.mbQuiet)
                .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotes(release: release) }
            Button("Update") { updater.install() }.buttonStyle(.mbPrimary).disabled(!updater.canInstall)
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check now") { updater.check(userInitiated: true) }.buttonStyle(.mbQuiet).disabled(!isBundled)
        }
    }
}

private struct ReleaseNotes: View {
    let release: Updater.Release
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maben Sweep \(release.version)").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text((try? AttributedString(markdown: release.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(release.notes))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Link("Open on GitHub", destination: release.page).font(.system(size: 12))
        }
        .frame(width: 320)
        .padding(16)
    }
}

/// This version's entry in CHANGELOG.md (bundled with the app), shown on About.
enum WhatsNew {
    static let items: [String] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var inSection = false, items: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.dropFirst(3).hasPrefix(version + " ")
            } else if inSection, line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)).replacingOccurrences(of: "`", with: ""))
            }
        }
        return items
    }()
}
