import AppKit

/// Owns scroll geometry, anchor selection and restoration for every editor feature.
final class EditorScrollCoordinator {
    enum Policy { case preserveViewport, followCursor, preserveVisibleCursor }
    enum Event { case markdownRendering, markdownModeChange, appearanceChange, externalTextChange }
    struct Anchor { let offset: Int; let screenY: CGFloat }
    struct ResizeAnchor { let location: any NSTextLocation; let offset: CGFloat }
    private weak var editor: NativeManuscriptTextView?
    private var pending: Anchor?
    init(editor: NativeManuscriptTextView) { self.editor = editor }

    // Feature-to-policy configuration lives here, alongside its implementation.
    func capture(for event: Event) -> Anchor? {
        switch event {
        case .markdownRendering, .externalTextChange: return capture(.preserveViewport)
        case .markdownModeChange: return capture(.preserveVisibleCursor)
        case .appearanceChange: return capture(.followCursor)
        }
    }

    func cancel() { pending = nil }
    func revealSelection() {
        guard let editor else { return }
        cancel()
        editor.scrollRangeToVisible(editor.selectedRange())
    }
    func reveal(_ rect: NSRect) {
        cancel()
        editor?.scrollToVisible(rect)
    }
    func layoutDidFinish() {
        guard let anchor = pending else { return }
        pending = nil
        apply(anchor)
    }

    func capture(_ policy: Policy) -> Anchor? {
        guard let editor, let scroll = editor.enclosingScrollView else { return nil }
        switch policy {
        case .followCursor:
            if editor.windowedDocument?.hasVirtualSelection == true { return capture(.preserveViewport) }
            let offset = editor.selectedRange().location
            if let pending, pending.offset == offset { return pending }
            if let anchor = visibleCursorAnchor() { return anchor }
            let anchor = Anchor(offset: offset, screenY: 0)
            restore(anchor)
            return anchor
        case .preserveVisibleCursor:
            if let pending, pending.offset == editor.selectedRange().location { return pending }
            return visibleCursorAnchor() ?? capture(.preserveViewport)
        case .preserveViewport:
            if let pending { return pending }
            let point = NSPoint(x: editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0),
                               y: scroll.contentView.bounds.minY + 1)
            // TextKit hit testing above the first text line can return the last
            // insertion position. Padding/top bounce must stay at the window's
            // start, otherwise prefetch mistakes an upward gesture for its tail.
            let offset = point.y <= editor.textContainerOrigin.y ? 0
                : min(editor.characterIndexForInsertion(at: point), editor.textStorage?.length ?? 0)
            guard let rect = editor.lineRect(at: offset) else { return nil }
            return Anchor(offset: offset, screenY: rect.minY + editor.textContainerOrigin.y - scroll.contentView.bounds.minY)
        }
    }

    private func visibleCursorAnchor() -> Anchor? {
        guard let editor, editor.windowedDocument?.hasVirtualSelection != true, let scroll = editor.enclosingScrollView,
              let manager = editor.textLayoutManager,
              let location = editor.textLocation(at: editor.selectedRange().location),
              let viewport = manager.textViewportLayoutController.viewportRange,
              location.compare(viewport.location) != .orderedAscending,
              location.compare(viewport.endLocation) != .orderedDescending,
              let rect = editor.lineRect(at: editor.selectedRange().location) else { return nil }
        let y = rect.minY + editor.textContainerOrigin.y - scroll.contentView.bounds.minY
        guard y >= 0, y + rect.height <= scroll.contentSize.height else { return nil }
        return Anchor(offset: editor.selectedRange().location, screenY: y)
    }

    func restore(_ anchor: Anchor) {
        pending = anchor
        apply(anchor)
    }
    private func apply(_ anchor: Anchor) {
        guard let editor, let manager = editor.textLayoutManager, let scroll = editor.enclosingScrollView,
              let location = editor.textLocation(at: anchor.offset) else { return }
        let controller = manager.textViewportLayoutController
        let y = controller.relocateViewport(to: location)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
            y: max(0, y + editor.textContainerOrigin.y - anchor.screenY)))
        controller.layoutViewport()
        // Relocation is an estimate. A partially clipped anchor can fall outside
        // TextKit's new viewport, so explicitly lay out its paragraph before the
        // final measurement. Never accept the estimate as a persistent position.
        manager.ensureLayout(for: NSTextRange(location: location))
        if let rect = editor.lineRect(at: anchor.offset) {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
                y: max(0, rect.minY + editor.textContainerOrigin.y - anchor.screenY)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // Resize uses the already laid-out TextKit location, avoiding document hit-testing.
    func captureResizeAnchor() -> ResizeAnchor? {
        guard let editor, let manager = editor.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange,
              let fragment = manager.textLayoutFragment(for: viewport.location),
              fragment.state == .layoutAvailable, let scroll = editor.enclosingScrollView else { return nil }
        return ResizeAnchor(location: viewport.location,
            offset: scroll.contentView.bounds.minY - fragment.layoutFragmentFrame.minY - editor.textContainerOrigin.y)
    }
    func restoreResizeAnchor(_ anchor: ResizeAnchor) {
        guard let editor, let manager = editor.textLayoutManager, let scroll = editor.enclosingScrollView else { return }
        let y = manager.textViewportLayoutController.relocateViewport(to: anchor.location)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX,
            y: max(0, y + editor.textContainerOrigin.y + anchor.offset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func snapshot() -> EditorViewportPosition? {
        guard let editor, let manager = editor.textLayoutManager, let content = manager.textContentManager,
              let scroll = editor.enclosingScrollView else { return nil }
        manager.textViewportLayoutController.layoutViewport()
        guard let viewport = manager.textViewportLayoutController.viewportRange else { return nil }
        let top = scroll.contentView.bounds.minY - editor.textContainerOrigin.y
        let cursor = editor.position(at: editor.selectedRange().location)
        let cursorText = lineText(cursor.line)
        var result: EditorViewportPosition?
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending else { return false }
            guard fragment.state == .layoutAvailable, fragment.layoutFragmentFrame.maxY > top else { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let row = editor.line(at: offset)
            var value = EditorViewportPosition(firstVisibleLine: row + 1, firstLineText: self.lineText(row),
                offsetWithinLine: Double(top - fragment.layoutFragmentFrame.minY),
                cursorLine: cursor.line + 1, cursorLineText: cursorText, cursorOffsetWithinLine: cursor.column)
            let column = min(max(0, cursor.column), cursorText.count)
            value.cursorTextBefore = String(cursorText.prefix(column).suffix(24))
            value.cursorTextAfter = String(cursorText.dropFirst(column).prefix(24))
            result = value
            return false
        }
        return result
    }

    func reopen(_ saved: EditorViewportPosition) {
        guard let editor else { return }
        let resolution = EditorViewportResolver.resolve(saved, lineCount: editor.lineStarts.count, lineText: lineText)
        if let row = resolution.cursorRow, let column = resolution.cursorColumn {
            editor.setSelectedRange(NSRange(location: editor.offset(line: row, column: column), length: 0))
        }
        let offset = resolution.firstTextMatched && saved.offsetWithinLine.isFinite ? saved.offsetWithinLine : 0
        restore(Anchor(offset: editor.lineStarts[resolution.firstRow], screenY: -CGFloat(offset)))
    }

    private func lineText(_ row: Int) -> String {
        guard let editor, let storage = editor.textStorage else { return "" }
        let row = min(max(0, row), editor.lineStarts.count - 1)
        let start = editor.lineStarts[row]
        let end = row + 1 < editor.lineStarts.count ? editor.lineStarts[row + 1] : storage.length
        return (storage.string as NSString).substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .newlines)
    }
}
