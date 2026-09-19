import AppKit

/// One ordering boundary for attribute-only changes:
/// attributes -> TextKit layout -> viewport restoration -> native insertion indicator.
/// Selection notifications may reenter presentation; nested changes join the outer batch.
final class ManuscriptPresentationCoordinator {
    private weak var editor: NativeManuscriptTextView?
    private var applying = false
    var isApplying: Bool { applying }

    init(editor: NativeManuscriptTextView) { self.editor = editor }

    func perform(for event: EditorScrollCoordinator.Event, changes: () -> Void) {
        guard let editor else { return }
        if applying { changes(); return }
        applying = true
        defer { applying = false }
        let selection = editor.selectedRange()
        let anchor = editor.scrollCoordinator.capture(for: event)
        editor.textContentStorage?.performEditingTransaction { changes() }
        // Initial configuration runs before the document is attached to its host.
        // Do not lay out an offscreen EOF or install a viewport anchor at that point.
        guard editor.enclosingScrollView != nil else {
            editor.needsLayout = true
            editor.needsDisplay = true
            return
        }
        if let manager = editor.textLayoutManager, let content = manager.textContentManager,
           let location = editor.textLocation(at: selection.location) {
            manager.invalidateLayout(for: content.documentRange)
            manager.ensureLayout(for: NSTextRange(location: location))
        }
        if let anchor { editor.scrollCoordinator.restore(anchor) }
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        // Restarting the blink timer before restoring the viewport leaves AppKit's
        // NSTextInsertionIndicator at its pre-reflow frame until the next scroll.
        editor.setSelectedRange(selection)
        editor.updateInsertionPointStateAndRestartTimer(true)
        editor.needsDisplay = true
    }
}
