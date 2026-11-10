import SwiftUI
import SweepCore

/// The window that drops down from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    var open: (Pane?) -> Void = { _ in }
    @State private var confirm = false

    var body: some View {
        let due = model.dueProjects
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(due.isEmpty ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(MB.accent.gradient))
                    BroomGlyph(size: 16).foregroundStyle(due.isEmpty ? MB.muted : Color.black)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MB.text)
                    Text(model.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(MB.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.hasScanned ? model.scan() : open(.projects) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MB.muted)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Scan now")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            UpdateNotice()

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                if !model.hasScanned {
                    message("Open Sweep to run the first scan. It only shows what could go.")
                } else if due.isEmpty {
                    message("No project has been idle for \(model.settings.idleDays) days. Sweep looks again once a day.")
                } else {
                    HStack {
                        Text("Idle projects")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MB.muted)
                        Spacer()
                        if due.count > 5 {
                            Text("\(due.count - 5) more in Sweep").font(.system(size: 11)).foregroundStyle(MB.dim)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    ForEach(due.prefix(5)) { project in
                        MenuRow(project: project) { open(.projects) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if !due.isEmpty {
                HStack(spacing: 8) {
                    if confirm {
                        Text("Free \(Format.bytes(model.dueBytes))?")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(MB.text)
                        Spacer()
                        Button("Cancel") { confirm = false }.buttonStyle(.mbQuiet)
                        Button("Clean") { confirm = false; model.cleanAllDue() }.buttonStyle(.mbPrimary)
                    } else {
                        Button { confirm = true } label: {
                            Text("Clean \(due.count) idle \(due.count == 1 ? "project" : "projects")").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.mbPrimary)
                        .disabled(!model.busy.isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 2) {
                FooterButton(title: "Open Sweep…", symbol: "macwindow") { open(nil) }
                    .keyboardShortcut("o", modifiers: .command)
                Spacer()
                FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(MB.bg.opacity(0.92))
        .environment(\.colorScheme, .dark)
        .tint(MB.accent)
        .background(GeometryReader { geo in WindowFitter(height: geo.size.height) })
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MB.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
    }
}

/// "Version 1.1 is available" with an Update button, at the top of the menu.
private struct UpdateNotice: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(MB.accent).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(release.version) is available").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.text)
                    Text(detail).font(.system(size: 11)).foregroundStyle(MB.muted)
                }
                Spacer()
                if case .available = updater.state {
                    Button("Update") { updater.install() }.buttonStyle(.mbPrimary).disabled(!updater.canInstall)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.accent.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.accent.opacity(0.3)))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var detail: String {
        switch updater.state {
        case .downloading(_, let p): "Downloading… \(Int(p * 100))%"
        case .installing: "Installing, restarts in a moment"
        default: updater.canInstall ? "Installs in a few seconds and restarts" : "Move the app to Applications to update"
        }
    }
}

private struct MenuRow: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MB.text)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text(project.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MB.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Format.ago(Planner.effectiveActivity(of: project, state: model.state)))
                    .font(.system(size: 11))
                    .foregroundStyle(MB.dim)
                Text(Format.bytes(project.safeBytes(kinds: model.settings.kinds)))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(MB.muted)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(MB.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// MenuBarExtra grows its window when the content gets taller but never shrinks it again.
/// Keep the window exactly as tall as the content, pinned to its top edge.
private struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { fit(view.window) }
    }

    private func fit(_ window: NSWindow?) {
        guard let window, height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - height) > 0.5 else { return }
        var frame = window.frame
        let delta = height - content.height
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true)
    }
}
