import SwiftUI

struct CommitDiffView: View {
    let document: CommitDiffDocument
    let close: () -> Void
    @State private var expansionState = CommitDiffExpansionState()

    init(patch: String, close: @escaping () -> Void) {
        document = CommitDiffDocument(patch: patch)
        self.close = close
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.get("git.commitDetails"), close: close) {
                Button(action: toggleExpansion) {
                    Label(L10n.get(allExpanded ? "git.collapseAll" : "git.expandAll"),
                          systemImage: allExpanded ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .labelStyle(.iconOnly)
                .help(L10n.get(allExpanded ? "git.collapseAll" : "git.expandAll"))
                .disabled(document.files.isEmpty)
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !document.summary.isEmpty {
                        Text(document.summary).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    ForEach(document.files) { file in
                        DisclosureGroup(isExpanded: expansion(file.id, in: $expansionState.collapsedFiles)) {
                            VStack(alignment: .leading, spacing: 8) {
                                if !file.metadata.isEmpty {
                                    Text(file.metadata.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                ForEach(file.hunks) { hunk in
                                    DisclosureGroup(isExpanded: expansion(hunk.id, in: $expansionState.collapsedHunks)) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(hunk.lines) { line in row(line) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    } label: {
                                        HStack {
                                            Text(hunk.header).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                            Spacer(); counts(hunk.added, hunk.removed)
                                        }.help(hunk.header)
                                    }
                                }
                            }.padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(file.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(); counts(file.added, file.removed)
                            }.help(file.title)
                        }
                        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(16)
            }
        }.frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 650)
    }
    private var allExpanded: Bool { expansionState.allExpanded }

    private func toggleExpansion() {
        expansionState.toggle(document: document)
    }
    private func expansion(_ id: Int, in collapsed: Binding<Set<Int>>) -> Binding<Bool> {
        Binding(get: { !collapsed.wrappedValue.contains(id) }, set: { expanded in
            if expanded { collapsed.wrappedValue.remove(id) } else { collapsed.wrappedValue.insert(id) }
        })
    }
    private func counts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(.green)
            Text("−\(removed)").foregroundStyle(.red)
        }.font(.system(size: 11, design: .monospaced)).fixedSize()
    }
    private func row(_ line: CommitDiffDocument.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 42, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .added ? Color.green.opacity(0.13) : line.kind == .removed ? Color.red.opacity(0.13) : Color.clear)
    }
}

struct CommitDiffExpansionState {
    var collapsedFiles: Set<Int> = []
    var collapsedHunks: Set<Int> = []
    var allExpanded: Bool { collapsedFiles.isEmpty && collapsedHunks.isEmpty }

    mutating func toggle(document: CommitDiffDocument) {
        if allExpanded {
            collapsedFiles = Set(document.files.map(\.id))
            collapsedHunks = Set(document.files.flatMap(\.hunks).map(\.id))
        } else {
            collapsedFiles = []
            collapsedHunks = []
        }
    }
}
