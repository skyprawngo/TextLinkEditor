import SwiftUI

struct CollaborationView: View {
    @Bindable var coordinator: CollaborationCoordinator
    @Bindable var git: ProjectGitModel
    @State private var comment = ""
    @State private var roots = ""
    @State private var answers: [String: String] = [:]
    @State private var reviewTask: CollaborationTaskRecord?
    @State private var configuration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = coordinator.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let message = coordinator.notification {
                    HStack(alignment: .top) {
                        Text(message).font(.callout)
                        Spacer()
                        Button { coordinator.notification = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.get("common.close"))
                    }
                }
                ProjectChangeReviewView(model: git, collaboration: coordinator)
                DisclosureGroup(L10n.get("collaboration.configuration"), isExpanded: $configuration) {
                    configurationView.padding(.top, 8)
                }
                if coordinator.commentAnchor != nil { commentView }
                Divider()
                Text(L10n.get("collaboration.tasks")).font(.headline)
                if coordinator.document.tasks.isEmpty {
                    Text(L10n.get("collaboration.empty")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(coordinator.document.tasks.reversed()) { task in taskView(task) }
            }.padding(14)
        }
        .onAppear {
            roots = coordinator.document.canonRoots.joined(separator: ", ")
            try? coordinator.refresh()
        }
        .onChange(of: coordinator.commentAnchor) { _, anchor in
            if anchor != nil { comment = "" }
        }
        .sheet(item: $reviewTask) { task in
            CollaborationReviewView(task: task, project: coordinator.project)
        }
    }

    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !coordinator.document.enabled {
                Button(L10n.get("collaboration.enable")) { coordinator.enable() }
            } else {
                Toggle(L10n.get("git.autoRun"), isOn: Binding(get: { !coordinator.document.paused }, set: { coordinator.configure(paused: !$0) }))
            }
            Text(L10n.get("collaboration.canonRoots")).font(.caption)
            TextField(L10n.get("collaboration.canonRoots"), text: $roots)
                .textFieldStyle(.roundedBorder)
            Button(L10n.get("common.save")) {
                coordinator.configure(roots: roots.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            Toggle(L10n.get("collaboration.git"), isOn: Binding(
                get: { coordinator.document.gitEnabled },
                set: { coordinator.configure(git: $0) }))
            Text(L10n.get("collaboration.gitHelp")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.get("collaboration.protectedFiles")) {
                let paths = Set(coordinator.document.baseline.keys).union(coordinator.pending.map(\.path)).sorted()
                ForEach(paths, id: \.self) { path in
                    Toggle(path, isOn: Binding(
                        get: { coordinator.document.protectedPaths.contains(path) },
                        set: { protect in
                            var values = coordinator.document.protectedPaths
                            if protect { values.insert(path) } else { values.remove(path) }
                            coordinator.configure(protected: values)
                        })).font(.caption)
                }
            }
        }
    }

    private var commentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.get("collaboration.comment")).font(.headline)
            if let anchor = coordinator.commentAnchor {
                Text(anchor.path).font(.caption).foregroundStyle(.secondary)
                Text(anchor.quote).font(.callout).lineLimit(5)
                Button(L10n.get("collaboration.clearSelection")) { coordinator.commentAnchor = nil }
            } else {
                Button(L10n.get("collaboration.commentSelection")) { coordinator.captureComment() }
                    .buttonStyle(.borderless)
            }
            TextEditor(text: $comment).frame(minHeight: 64, maxHeight: 120)
                .padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(L10n.get("collaboration.comment"))
            Button(L10n.get("collaboration.submitComment")) {
                coordinator.submitComment(comment, anchor: coordinator.commentAnchor)
                if coordinator.error == nil { comment = "" }
            }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func taskView(_ task: CollaborationTaskRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(task.origin == "conversation" ? L10n.get("collaboration.chatTask") : task.instruction)
                    .font(.callout).textSelection(.enabled)
                if let anchor = task.anchor {
                    Text(anchor.path + "\n" + anchor.quote).font(.caption).textSelection(.enabled)
                }
                if !task.summary.isEmpty { Text(task.summary).font(.callout).textSelection(.enabled) }
                if let error = task.error { Text(error).font(.caption).foregroundStyle(.red) }
                ForEach(task.questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question).font(.callout.bold())
                        ForEach(Array(question.evidence.enumerated()), id: \.offset) { _, item in
                            Text(item.path + ": " + item.quote).font(.caption).foregroundStyle(.secondary)
                        }
                        if let answer = question.answer { Text(answer).font(.callout) }
                        else {
                            ForEach(question.options, id: \.self) { option in
                                Button(option) { coordinator.answer(taskID: task.id, questionID: question.id, text: option) }
                            }
                            let key = task.id.uuidString + question.id
                            TextField(L10n.get("collaboration.answer"), text: Binding(
                                get: { answers[key] ?? "" }, set: { answers[key] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.get("collaboration.sendAnswer")) {
                                coordinator.answer(taskID: task.id, questionID: question.id, text: answers[key] ?? "")
                            }
                        }
                    }
                }
                HStack {
                    Button(L10n.get("collaboration.compare")) { reviewTask = task }
                    if [.failed, .review, .cancelled].contains(task.phase) {
                        Button(L10n.get("common.retry")) { coordinator.retry(task.id) }
                    }
                    if task.phase.isRunning || [.queued, .waiting].contains(task.phase) {
                        Button(L10n.get("common.cancel")) { coordinator.cancel(task.id); try? coordinator.refresh() }
                    }
                    if !task.transactionIDs.isEmpty && task.phase != .reverted {
                        Button(L10n.get("collaboration.undo")) { coordinator.undo(task.id) }.disabled(coordinator.isWorking)
                    }
                }.buttonStyle(.borderless)
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.phase.title).font(.callout.bold())
                Text(task.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CollaborationReviewView: View {
    let task: CollaborationTaskRecord
    let project: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [CollaborationChange] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: L10n.get("collaboration.compare")) { dismiss() }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                        Text(change.path).font(.headline)
                        if let reason = task.proposal?.edits.first(where: { $0.path == change.path }) {
                            Text(reason.reason).font(.callout)
                            ForEach(Array(reason.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text(evidence.path + ": " + evidence.quote).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        let revision = ManuscriptRevision(id: task.id, relativePath: change.path, original: change.before ?? "",
                            selectionLocation: 0, selectionLength: (change.before ?? "").utf16.count)
                        ForEach(revision.changes(proposal: change.after ?? "")) { hunk in
                            Text("− " + hunk.before).foregroundStyle(.red).textSelection(.enabled)
                            Text("+ " + hunk.after).foregroundStyle(.green).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 620, minHeight: 440)
        .onAppear {
            guard let project else { return }
            do {
                changes = try CollaborationStore(project: project).journals()
                    .filter { $0.taskID == task.id }.flatMap(\.changes)
                if changes.isEmpty { changes = task.changes }
            } catch { self.error = error.localizedDescription }
        }
    }
}
