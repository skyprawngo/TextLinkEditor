import SwiftUI

/// The workspace agent has already saved these edits. This view never reapplies prose or patches.
struct AIWorkspaceRevisionView: View {
    let record: AIWorkspaceRevision
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?
    private var selectedChange: AIWorkspaceChange? {
        record.changes.first { $0.relativePath == selectedPath } ?? record.changes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: L10n.get("revision.title")) { dismiss() }
            Text(L10n.get("revision.savedExplanation")).font(.callout).foregroundStyle(.secondary)
            if record.changes.isEmpty {
                ContentUnavailableView(L10n.get("revision.noChanges"), systemImage: "doc.text.magnifyingglass")
            } else {
                Picker(L10n.get("revision.file"), selection: Binding(get: {
                    selectedChange?.relativePath ?? ""
                }, set: { selectedPath = $0 })) {
                    ForEach(record.changes) { change in Text(change.relativePath).tag(change.relativePath) }
                }
                if let change = selectedChange {
                    HStack(alignment: .top, spacing: 16) {
                        pane(change.before, title: "revision.original")
                        pane(change.after, title: "revision.saved")
                    }
                }
            }
        }.padding(20).frame(minWidth: 760, minHeight: 520)
    }

    private func pane(_ text: String?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.get(title)).font(.headline)
            AIRevisionTextPane(text: text ?? L10n.get("revision.fileAbsent"))
                .background(AppColors.textEditorBackground, in: RoundedRectangle(cornerRadius: 8))

        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


/// Native TextKit 2 viewport layout keeps the entire saved revision searchable and scrollable.
private struct AIRevisionTextPane: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.frame = NSRect(x: 0, y: 0, width: 350, height: 480)
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.usesFindBar = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
