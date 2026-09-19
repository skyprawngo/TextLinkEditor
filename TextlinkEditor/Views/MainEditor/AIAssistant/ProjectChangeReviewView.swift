import SwiftUI

/// A Git change, its immutable comparison, and an author instruction live together.
struct ProjectChangeReviewView: View {
    @Bindable var model: ProjectGitModel
    let collaboration: CollaborationCoordinator
    @State private var selectedExcerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.get("git.changes")).font(.headline)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.get("git.refresh"))
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !model.snapshot.exists {
                Text(L10n.get("git.collaborationHint")).font(.callout).foregroundStyle(.secondary)
            } else {
                Label(model.snapshot.branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                LiquidGlassSegmentedControl(
                    title: L10n.get("git.changeSource"), selection: $model.scope,
                    options: ProjectGitScope.allCases, label: { $0.title }
                )
                let changes = model.snapshot.changes.filter { model.scope == .staged ? $0.staged : $0.unstaged }
                if changes.isEmpty { Text(L10n.get("git.clean")).font(.callout).foregroundStyle(.secondary) }
                ForEach(changes) { change in
                    Button { model.select(change, scope: model.scope, collaboration: collaboration) } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(change.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(model.scope == .staged ? change.index : change.worktree).foregroundStyle(.orange)
                        }.font(.callout).padding(7).background(model.selectedDiff?.path == change.path ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if let diff = model.selectedDiff, diff.scope == model.scope { review(diff) }
                else { Text(L10n.get("git.selectChange")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: model.selectedDiff?.id) { _, _ in selectedExcerpt = nil }
        .onChange(of: model.scope) { _, _ in selectedExcerpt = nil }
    }
    private func review(_ diff: ProjectGitDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(diff.path).font(.callout.bold()).textSelection(.enabled)
            if diff.binary { Text(L10n.get("git.binary")).font(.caption).foregroundStyle(.secondary) }
            else {
                let patch = diff.patch.isEmpty ? (diff.after ?? diff.before ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { (diff.after == nil ? "-" : "+") + $0 }.joined(separator: "\n") : diff.patch
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(patch.components(separatedBy: "\n").enumerated()), id: \.offset) { offset, line in
                            HStack(alignment: .top, spacing: 5) {
                                if line.hasPrefix("@@") {
                                    Button {
                                        let lines = patch.components(separatedBy: "\n")
                                        let end = lines.indices.dropFirst(offset + 1).first(where: { lines[$0].hasPrefix("@@") }) ?? lines.count
                                        selectedExcerpt = lines[offset..<end].joined(separator: "\n")
                                    } label: { Image(systemName: "text.bubble") }
                                        .buttonStyle(.borderless).help(L10n.get("git.annotateHunk"))
                                        .accessibilityLabel(L10n.get("git.annotateHunk"))
                                }
                                Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .secondary : .primary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(minHeight: 100, maxHeight: 240).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                if let selectedExcerpt {
                    HStack {
                        Text(L10n.get("git.selectedHunk")).font(.caption)
                        Spacer()
                        Button { self.selectedExcerpt = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }.help(selectedExcerpt)
                }
                TextField(L10n.get("git.instruction"), text: Binding(
                    get: { model.instructions[diff.id] ?? "" }, set: { model.instructions[diff.id] = $0 }), axis: .vertical)
                    .lineLimit(3...7).textFieldStyle(.roundedBorder)
                Button(L10n.get("git.sendInstruction")) { model.submit(diff, excerpt: selectedExcerpt, to: collaboration) }
                    .disabled(model.busy || !CollaborationStore.validPath(diff.path) || (model.instructions[diff.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(L10n.get("git.instructionHelp")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
