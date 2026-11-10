import AppKit
import SwiftUI

/// The Sweep window, in the same Maben style as Maben Awake's Settings: a dark sidebar with
/// the wordmark and the pages, and the page on the right, in a window of fixed width.
@MainActor
final class Navigation: ObservableObject {
    @Published var pane: Pane = .projects
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController(model: .shared)
    static let size = NSSize(width: 780, height: 600)
    let navigation = Navigation()

    init(model: AppModel) {
        let root = WindowRoot().environmentObject(model).environmentObject(navigation)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(Self.size)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Maben Sweep"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Maben is dark, like the website, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.035, green: 0.035, blue: 0.04, alpha: 1)
        // Taller is allowed (long project lists); the width stays fixed.
        window.contentMinSize = NSSize(width: Self.size.width, height: 480)
        window.contentMaxSize = NSSize(width: Self.size.width, height: 2000)
        window.setFrameAutosaveName("MabenSweepWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings the window to the front, optionally on a given page.
    func show(_ pane: Pane? = nil) {
        if let pane { navigation.pane = pane }
        if window?.isVisible != true, UserDefaults.standard.string(forKey: "NSWindow Frame MabenSweepWindow") == nil {
            window?.center()
        }
        // A menu bar app has no Dock icon; show one while the window is open so it can be found with ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Sidebar plus the selected page.
struct WindowRoot: View {
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 210)
                .background(MB.sidebar)
            Rectangle().fill(MB.line).frame(width: 1)
            navigation.pane.view
                .id(navigation.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(MB.bg)
        }
        .ignoresSafeArea()
        .frame(width: MainWindowController.size.width)
        .frame(minHeight: 480, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(MB.accent)
        .background(KeyboardNavigation())
    }
}

/// ⌘1–⌘6 jump to a page; ⌘↑ and ⌘↓ go to the previous or next one.
private struct KeyboardNavigation: View {
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        let panes = Pane.allCases
        ZStack {
            ForEach(Array(panes.enumerated()), id: \.offset) { i, pane in
                Button("") { navigation.pane = pane }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let panes = Pane.allCases
        guard let i = panes.firstIndex(of: navigation.pane) else { return }
        navigation.pane = panes[(i + d + panes.count) % panes.count]
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var navigation: Navigation
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MBWordmark(size: 17)
                .padding(.leading, 10)
                .padding(.top, 38)
                .padding(.bottom, 30)
            ForEach(Array(Pane.allCases.dropLast().enumerated()), id: \.offset) { i, pane in
                SidebarRow(pane: pane, shortcut: i + 1, selected: navigation.pane == pane) { navigation.pane = pane }
            }
            Spacer()
            SidebarRow(pane: .about, shortcut: Pane.allCases.count, selected: navigation.pane == .about) { navigation.pane = .about }
            HStack(spacing: 7) {
                Circle()
                    .fill(model.settings.automatic ? MB.accent : MB.dim)
                    .frame(width: 7, height: 7)
                    .shadow(color: model.settings.automatic ? MB.accent.opacity(0.6) : .clear, radius: 3)
                Text(model.settings.automatic ? "Automatic cleanup is on" : "Automatic cleanup is off")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MB.muted)
            }
            .padding(.leading, 10)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 12)
    }
}

private struct SidebarRow: View {
    let pane: Pane
    let shortcut: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? MB.accent : MB.muted)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? MB.text : MB.muted)
                Spacer(minLength: 0)
                if hovering && !selected {
                    Text("⌘\(shortcut)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(MB.dim)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? MB.accent.opacity(0.13) : Color.white.opacity(hovering ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? MB.accent.opacity(0.28) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(pane.title) (⌘\(shortcut))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
