import SwiftUI
import AppKit

struct ProjectReplaceView: View {
    let projectURL: URL
    let initialQuery: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var replacement = ""
    @State private var preview: ProjectReplacementStore.Preview?
    @State private var selection = Set<String>()
    @State private var focusedPath: String?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var lastBatch: ProjectReplacementStore.Batch?
    private var focused: ProjectReplacementStore.Change? { preview?.changes.first { $0.relativePath == focusedPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: L10n.get("projectReplace.title"), isCloseDisabled: busy, close: { dismiss() }) {
                if busy { ProgressView().controlSize(.small) }
            }
            Text(L10n.get("projectReplace.description")).font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L10n.get("projectReplace.find"), text: $query)
                TextField(L10n.get("projectReplace.replace"), text: $replacement)
                Button(L10n.get("projectReplace.preview")) { scan() }.disabled(query.isEmpty || busy)
            }.textFieldStyle(.roundedBorder).disabled(busy)
            if let preview {
                HSplitView {
                    List(preview.changes, selection: $focusedPath) { change in
                        HStack {
                            Toggle("", isOn: Binding(get: { selection.contains(change.id) }, set: {
                                if $0 { selection.insert(change.id) } else { selection.remove(change.id) }
                            })).labelsHidden().accessibilityLabel(change.relativePath)
                            VStack(alignment: .leading) {
                                Text(change.relativePath).lineLimit(2)
                                Text(String(format: L10n.get("projectReplace.count"), change.occurrences)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(change.relativePath)
                    }.frame(minWidth: 190, idealWidth: 240, maxWidth: 320)
                    if let focused {
                        HStack(spacing: 8) {
                            VStack {
                                Text(L10n.get("projectReplace.before")).font(.caption)
                                ReplacementPreview(content: focused.original)
                            }
                            VStack {
                                Text(L10n.get("projectReplace.after")).font(.caption)
                                ReplacementPreview(content: focused.replacement)
                            }
                        }.frame(minWidth: 400)
                    } else {
                        ContentUnavailableView(L10n.get("projectReplace.noMatches"), systemImage: "text.magnifyingglass")
                    }
                }.disabled(busy)
                if preview.skipped > 0 || preview.limitReached {
                    Text(L10n.get("projectReplace.limits")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(L10n.get("projectReplace.previewFirst"), systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.get("projectReplace.selectAll")) { selection = Set(preview?.changes.map(\.id) ?? []) }.disabled(busy)
                Button(L10n.get("projectReplace.selectNone")) { selection = [] }.disabled(busy)
                Spacer()
                if lastBatch != nil { Button(L10n.get("projectReplace.undo")) { undo() }.disabled(busy) }
                Button(L10n.get("projectReplace.apply")) { apply() }.disabled(busy || selection.isEmpty)
            }
        }.padding(20).frame(minWidth: 820, minHeight: 520)
            .onAppear { query = initialQuery }
            .onChange(of: query) { _, _ in invalidate() }
            .onChange(of: replacement) { _, _ in invalidate() }
            .interactiveDismissDisabled(busy)
    }

    private func invalidate() { preview = nil; selection = []; focusedPath = nil }
    private func scan() {
        let query = query, replacement = replacement, project = projectURL
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectReplacementStore.preview(projectURL: project, query: query, replacement: replacement)
                }.value
                preview = result
                selection = Set(result.changes.map(\.id))
                focusedPath = result.changes.first?.id
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func validateClean(_ changes: [ProjectReplacementStore.Change]) throws {
        EditorTabManager.shared.flushEditor()
        for change in changes {
            let url = try ProjectReplacementStore.documentURL(projectURL: projectURL, relativePath: change.relativePath)
            if EditorTabManager.shared.isModified(url: url) {
                throw ProjectReplacementStore.Failure.changed(change.relativePath)
            }
        }
    }
    private func apply() {
        let changes = preview?.changes.filter { selection.contains($0.id) } ?? []
        do { try validateClean(changes) } catch { errorMessage = error.localizedDescription; return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                lastBatch = try await Task.detached(priority: .userInitiated) {
                    try ProjectReplacementStore.apply(projectURL: projectURL, changes: changes)
                }.value
                invalidate()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func undo() {
        guard let batch = lastBatch else { return }
        do { try validateClean(batch.changes) } catch { errorMessage = error.localizedDescription; return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ProjectReplacementStore.undo(projectURL: projectURL, batch: batch)
                }.value
                lastBatch = nil
                invalidate()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ReplacementPreview: NSViewRepresentable {
    let content: String
    final class Coordinator { var previous: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .textColor; text.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.previous != content, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.previous = content; text.string = content
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
