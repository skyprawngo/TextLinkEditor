import SwiftUI

struct ProjectGitSidebar: View {
    @Bindable var model: ProjectGitModel
    let collaboration: CollaborationCoordinator
    @AppStorage("git.sidebar.changesExpanded") private var changesExpanded = true
    @AppStorage("git.sidebar.graphExpanded") private var graphExpanded = true
    @State private var confirmInitialize = false
    @State private var confirmCommit = false
    @State private var pushAfterCommit = false
    @State private var confirmPush = false

    var body: some View {
        VStack(spacing: 0) {
            header("git.changes", expanded: $changesExpanded, count: model.snapshot.changes.count)
            if changesExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).help(error) }
                    if !model.snapshot.exists {
                        Text(L10n.get("git.noRepository")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.get("git.initialize")) { confirmInitialize = true }.disabled(model.busy || model.project == nil)
                    } else {
                        Label(model.snapshot.branch, systemImage: "arrow.triangle.branch").font(.caption).lineLimit(1)
                        TextField(L10n.get("git.commitMessage"), text: $model.commitMessage).textFieldStyle(.roundedBorder)
                            .disabled(model.busy)
                        commitButton
                        if model.busy { ProgressView().controlSize(.small) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                group(.staged)
                                group(.working)
                                if model.snapshot.changes.isEmpty { Text(L10n.get("git.clean")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxHeight: 135)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            header("git.graph", expanded: $graphExpanded, count: model.snapshot.commits.count)
            if graphExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.snapshot.commits.isEmpty { Text(L10n.get("git.noCommits")).font(.caption).foregroundStyle(.secondary).padding(10) }
                        ForEach(model.snapshot.commits) { commit in
                            Button { model.showCommit(commit.id) } label: {
                                HStack(spacing: 4) {
                                    graph(commit).frame(width: 34, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                                        Text(commit.refs.isEmpty ? String(commit.id.prefix(7)) + " · " + commit.author : commit.refs)
                                            .font(.system(size: 9)).foregroundStyle(commit.refs.isEmpty ? Color.secondary : Color.accentColor).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(commit.subject + "\n" + commit.author + " · " + commit.date)
                        }
                    }.padding(.horizontal, 6)
                }.frame(maxHeight: 160)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(L10n.get("git.initializeConfirm"), isPresented: $confirmInitialize) {
            Button(L10n.get("git.initialize")) { model.perform { try $0.initialize() } }
        }
        .confirmationDialog(L10n.get(pushAfterCommit ? "git.commitPushConfirm" : "git.commitConfirm"), isPresented: $confirmCommit) {
            Button(L10n.get(pushAfterCommit ? "git.commitPush" : "git.commit")) {
                model.commit(pushAfter: pushAfterCommit) { try await AIAssistantViewModel.shared.generateCommitMessage(patch: $0) }
            }
        } message: { Text(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.get("git.autoCommitHint") : model.commitMessage) }
        .confirmationDialog(L10n.get("git.pushConfirm"), isPresented: $confirmPush) {
            Button(L10n.get("git.push")) { model.push() }
        }
        .sheet(isPresented: Binding(get: { model.commitDetails != nil }, set: { if !$0 { model.commitDetails = nil } })) {
            CommitDiffView(patch: model.commitDetails ?? "") { model.commitDetails = nil }
        }
    }
    private var commitButton: some View {
        HStack(spacing: 0) {
            Button { pushAfterCommit = false; confirmCommit = true } label: {
                Label(L10n.get("git.commit"), systemImage: "checkmark")
                    .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.canCommit)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 18)
            Menu {
                Button(L10n.get("git.commit")) { pushAfterCommit = false; confirmCommit = true }.disabled(!model.canCommit)
                Button(L10n.get("git.commitPush")) { pushAfterCommit = true; confirmCommit = true }.disabled(!model.canCommit)
                Divider()
                Button(L10n.get("git.push")) { confirmPush = true }
                    .disabled(model.busy || !model.snapshot.exists || model.snapshot.commits.isEmpty)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 27, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.get("git.commitActions")).disabled(model.busy)
        }
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func header(_ key: String, expanded: Binding<Bool>, count: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 5) {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text(L10n.get(key)).font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.get(key))
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain).help(L10n.get("git.refresh")).accessibilityLabel(L10n.get("git.refresh")).disabled(model.busy)
            }.padding(.horizontal, 10).frame(height: 28)
        }
    }
    @ViewBuilder private func group(_ scope: ProjectGitScope) -> some View {
        let changes = model.snapshot.changes.filter { scope == .staged ? $0.staged : $0.unstaged }
        if !changes.isEmpty {
            Text(scope.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(changes) { change in
                HStack(spacing: 5) {
                    Button { model.select(change, scope: scope, collaboration: collaboration) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(change.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(scope == .staged ? change.index : change.worktree).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(change.path + " · " + L10n.get("git.review"))
                    Button {
                        let path = change.path
                        if scope == .staged { model.perform { try $0.unstage(path) } }
                        else { model.perform({ try $0.stage(path) }, saveDrafts: true) }
                    } label: { Image(systemName: scope == .staged ? "minus" : "plus").font(.system(size: 11)) }
                        .buttonStyle(.plain).disabled(model.busy)
                        .help(L10n.get(scope == .staged ? "git.unstage" : "git.stage"))
                        .accessibilityLabel(L10n.get(scope == .staged ? "git.unstage" : "git.stage") + " " + change.path)
                }.frame(height: 23)
            }
        }
    }
    private func graph(_ commit: ProjectGitCommit) -> some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { 5 + CGFloat(lane) * 7 }
            var stem = Path()
            stem.move(to: CGPoint(x: x(commit.lane), y: 0))
            stem.addLine(to: CGPoint(x: x(commit.lane), y: 16))
            context.stroke(stem, with: .color(.accentColor), lineWidth: 1.4)
            for line in commit.lines {
                var path = Path()
                path.move(to: CGPoint(x: x(line.from), y: line.from == commit.lane ? 16 : 0))
                path.addLine(to: CGPoint(x: x(line.to), y: size.height))
                context.stroke(path, with: .color([Color.blue, .purple, .green, .orange][line.from % 4]), lineWidth: 1.4)
            }
            let dot = CGRect(x: x(commit.lane) - 3, y: 13, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
        }.clipped().accessibilityHidden(true)
    }
}
