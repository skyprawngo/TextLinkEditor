import AppKit

/// Owns the transient panel, its source anchor and paragraph reservation.
/// Never inserts marker characters into the manuscript.
final class ManuscriptInlinePanelController {
    private weak var editor: NativeManuscriptTextView?
    private(set) var panel: NSView?
    private var anchor = 0
    private var localAnchor: Int? {
        guard let editor else { return nil }
        let base = editor.windowedDocument?.range.location ?? 0
        let length = editor.textStorage?.length ?? 0
        guard anchor >= base, anchor <= base + length else { return nil }
        return anchor - base
    }
    private let topMargin: CGFloat = 8
    private var reservedHeight: CGFloat { 100 + topMargin }

    init(editor: NativeManuscriptTextView) { self.editor = editor }

    func install(_ panel: NSView) {
        guard let editor else { return }
        close()
        let source = editor.documentText as NSString
        let selection = editor.documentSelection
        let end = min(source.length, selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location)
        let line = source.lineRange(for: NSRange(location: end, length: 0))
        anchor = line.length == 0 ? source.length : NSMaxRange(line) - 1
        self.panel = panel
        editor.addSubview(panel)
        if localAnchor == nil, let projection = editor.windowedDocument {
            projection.install(projection.document.range(around: anchor), selection: selection,
                               anchor: .init(offset: anchor, screenY: editor.visibleRect.height / 2))
        }
        invalidateLayout()
        editor.scrollCoordinator.reveal(panel.frame)
    }

    func close() {
        guard let panel else { return }
        panel.removeFromSuperview()
        self.panel = nil
        invalidateLayout()
    }

    func willReplace(_ range: NSRange, with replacement: String) {
        guard panel != nil else { return }
        if NSMaxRange(range) <= anchor {
            anchor += replacement.utf16.count - range.length
        } else if range.location <= anchor {
            anchor = range.location + replacement.utf16.count
        }
    }

    func textDidChange() {
        guard panel != nil, let editor else { return }
        anchor = min(max(0, anchor), editor.windowedDocument?.document.length ?? editor.textStorage?.length ?? 0)
        invalidateLayout()
    }

    func makeFragment(for element: NSTextElement, manager: NSTextLayoutManager) -> NSTextLayoutFragment {
        let fragment = ManuscriptLayoutFragment(textElement: element, range: element.elementRange)
        if panel != nil, let anchor = localAnchor, let content = manager.textContentManager, let range = element.elementRange {
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            if anchor >= start && (anchor < end || (anchor == end && end == editor?.textStorage?.length)) {
                fragment.panelHeight = reservedHeight
            }
        }
        return fragment
    }

    func layout() {
        guard let editor, let panel else { return }
        guard let anchor = localAnchor else { panel.isHidden = true; return }
        panel.isHidden = false
        guard let location = editor.textLocation(at: anchor),
              let fragment = editor.layoutFragment(at: location), fragment.state == .layoutAvailable else { return }
        let y = fragment.layoutFragmentFrame.maxY - reservedHeight + topMargin + editor.textContainerOrigin.y
        let viewport = editor.enclosingScrollView.map { editor.convert($0.contentView.bounds, from: $0.contentView) } ?? editor.bounds
        let inset = editor.textContainerOrigin.x
        var left = viewport.minX
        if let scroll = editor.enclosingScrollView, scroll.rulersVisible,
           let ruler = scroll.verticalRulerView, !ruler.isHidden {
            let rulerFrame = editor.convert(ruler.bounds, from: ruler)
            left = max(left, min(viewport.maxX, rulerFrame.maxX))
        }
        panel.frame = NSRect(x: left + inset, y: y,
            width: max(0, viewport.maxX - left - 2 * inset), height: reservedHeight - topMargin - 8)
    }

    private func invalidateLayout() {
        guard let editor, let anchor = localAnchor, let manager = editor.textLayoutManager,
              let location = editor.textLocation(at: anchor) else { return }
        let fragment = editor.layoutFragment(at: location)
        if let custom = fragment as? ManuscriptLayoutFragment {
            custom.panelHeight = panel == nil ? 0 : reservedHeight
            custom.invalidateLayout()
        }
        let range = fragment?.rangeInElement ?? NSTextRange(location: location)
        manager.invalidateLayout(for: range)
        manager.ensureLayout(for: range)
        manager.textViewportLayoutController.layoutViewport()
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        editor.needsDisplay = true
    }
}

private final class ManuscriptLayoutFragment: NSTextLayoutFragment {
    var panelHeight: CGFloat = 0
    override var bottomMargin: CGFloat { super.bottomMargin + panelHeight }
}
