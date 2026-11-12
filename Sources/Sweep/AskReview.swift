import SwiftUI
import SweepCore

/// Every folder that asks first in some projects, each with a tick, to remove them in one go
/// instead of one Remove and one confirmation per folder. Seeing the list and pressing Remove
/// is the OK; the cleaner still checks every folder again right before it goes.
struct AskReview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projects: [Project]
    @State private var chosen: Set<String>

    init(projects: [Project], chosen: Set<String>) {
        self.projects = projects
        _chosen = State(initialValue: chosen)
    }

    private var all: [Artifact] { projects.flatMap(\.askArtifacts) }
    private var picked: [Artifact] { all.filter { chosen.contains($0.path) } }
    private var pickedBytes: Int64 { picked.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(MB.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(projects) { project in
                        AskReviewProject(project: project, chosen: $chosen)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            .frame(minHeight: 120, maxHeight: 420)
            Divider().overlay(MB.line)
            footer
        }
        .frame(width: 580)
        .background(MB.bg)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(projects.count == 1 ? "Remove from \(projects[0].name)" : "Folders that ask first")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MB.text)
                Spacer(minLength: 8)
                Button(chosen.count == all.count ? "Select none" : "Select all") {
                    chosen = chosen.count == all.count ? [] : Set(all.map(\.path))
                }
                .buttonStyle(.mbQuiet)
                .disabled(all.isEmpty)
            }
            Text("Sweep can't prove these come back exactly as they were, so they never go automatically. "
                 + "The reason is under each one. Folders in idle projects start ticked, Python environments don't.")
                .font(.system(size: 12))
                .foregroundStyle(MB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.settings.removal == .trash ? "They go to the Trash." : "They are deleted right away.")
                .font(.system(size: 12))
                .foregroundStyle(MB.dim)
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .buttonStyle(.mbQuiet)
                .keyboardShortcut(.cancelAction)
            Button(removeTitle) {
                model.removeChosen(picked)
                dismiss()
            }
            .buttonStyle(.mbPrimary)
            .disabled(picked.isEmpty)
        }
        .padding(18)
    }

    private var removeTitle: String {
        let n = picked.count
        return n == 0 ? "Remove" : "Remove \(n) \(n == 1 ? "folder" : "folders") · \(Format.bytes(pickedBytes))"
    }
}

/// One project in the review: a tick for all of its folders, then one per folder.
private struct AskReviewProject: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    @Binding var chosen: Set<String>

    private var paths: [String] { project.askArtifacts.map(\.path) }
    private var state: AskCheck.State {
        let n = paths.filter(chosen.contains).count
        return n == 0 ? .off : n == paths.count ? .on : .mixed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if state == .on { chosen.subtract(paths) } else { chosen.formUnion(paths) }
            } label: {
                HStack(spacing: 10) {
                    AskCheck(state: state)
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MB.text)
                        .lineLimit(1)
                    Text("Last used \(Format.ago(Planner.effectiveActivity(of: project, state: model.state)))")
                        .font(.system(size: 12))
                        .foregroundStyle(MB.dim)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityLabel("All folders in \(project.name)")

            ForEach(project.askArtifacts) { artifact in
                AskReviewLine(artifact: artifact, isOn: Binding(
                    get: { chosen.contains(artifact.path) },
                    set: { if $0 { chosen.insert(artifact.path) } else { chosen.remove(artifact.path) } }
                ))
            }
        }
    }
}

private struct AskReviewLine: View {
    let artifact: Artifact
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                AskCheck(state: isOn ? .on : .off)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.relativePath)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MB.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MB.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(Format.bytes(artifact.bytes))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(MB.muted)
            }
            .padding(.leading, 24)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(artifact.relativePath)
        .accessibilityValue(isOn ? "selected" : "not selected")
    }

    private var detail: String {
        let reason = artifact.reason ?? "Needs your OK"
        let back = artifact.restore.map { " · back with \($0)" } ?? ""
        return reason + back
    }
}

/// A tick box: on, off, or some of a group.
private struct AskCheck: View {
    enum State { case on, off, mixed }
    let state: State

    var body: some View {
        Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
            .font(.system(size: 14))
            .foregroundStyle(state == .off ? MB.dim : MB.accent)
            .frame(width: 14)
    }
}
