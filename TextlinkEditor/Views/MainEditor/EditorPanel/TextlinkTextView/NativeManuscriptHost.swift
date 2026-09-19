import AppKit

final class NativeManuscriptHost: NSScrollView {
    private lazy var scrollMotion = EditorScrollMotion(scroll: self)
    override func scrollWheel(with event: NSEvent) {
        if scrollMotion.handle(event) {
            // The owner of the stretch also owns its terminal events. Passing an
            // ended event to AppKit here starts a second scrolling animator over
            // the same out-of-bounds clip geometry.
            return
        }
        super.scrollWheel(with: event)
    }
    override var documentView: NSView? {
        didSet { scrollMotion.cancel() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { scrollMotion.cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
    var textView: NativeManuscriptTextView { documentView as! NativeManuscriptTextView }
    func setRulerWidth(_ width: Double) {
        let width = EditorRulerAppearance.bounded(width)
        guard let ruler = verticalRulerView, ruler.ruleThickness != width else { return }
        let anchor = textView.scrollCoordinator.captureResizeAnchor()
        ruler.ruleThickness = width
        tile()
        textView.layoutSubtreeIfNeeded()
        if let anchor { textView.scrollCoordinator.restoreResizeAnchor(anchor) }
        ruler.needsDisplay = true
    }
    override func tile() {
        super.tile()
        updateBottomScrollSpace()
        // AppKit can reserve the ruler as a clip-view inset instead of shrinking
        // contentSize. Wrapping must exclude that space, including on tab swaps.
        let insets = contentView.contentInsets
        let width = max(0, contentView.bounds.width - insets.left - insets.right)
        if let documentView, documentView.frame.width != width {
            documentView.setFrameSize(NSSize(width: width, height: documentView.frame.height))
        }
        // Sidebar/assistant animation can resize the clip view without text edits.
        documentView?.needsLayout = true
    }

    private var updatingBottomSpace = false
    private var measuredTail: (editor: ObjectIdentifier, generation: Int, width: CGFloat,
                               style: String, contentHeight: CGFloat, tailHeight: CGFloat)?
    func updateBottomScrollSpace() {
        guard !updatingBottomSpace, let editor = documentView as? NativeManuscriptTextView else { return }
        updatingBottomSpace = true
        defer { updatingBottomSpace = false }
        let font = editor.typingAttributes[.font] as? NSFont ?? editor.font ?? .systemFont(ofSize: 14)
        let multiple = editor.defaultParagraphStyle?.lineHeightMultiple ?? 1
        var tailHeight = (font.ascender - font.descender + font.leading) * max(1, multiple)
            + editor.textContainerInset.height
        var contentHeight = editor.frame.height
        if let measuredTail, measuredTail.editor == ObjectIdentifier(editor),
           measuredTail.generation == editor.textEditGeneration,
           measuredTail.width == editor.frame.width, measuredTail.style == editor.styleKey {
            tailHeight = measuredTail.tailHeight
            contentHeight = measuredTail.contentHeight
        }
        // Use the final visual line once TextKit has laid it out. Do not force a
        // large document's offscreen tail to lay out merely to size scroll space.
        if let manager = editor.textLayoutManager, let content = manager.textContentManager,
           let viewport = manager.textViewportLayoutController.viewportRange,
           viewport.endLocation.compare(content.documentRange.endLocation) == .orderedSame,
           let lastLine = editor.lineRect(at: editor.textStorage?.length ?? 0) {
            tailHeight = lastLine.height + editor.textContainerInset.height
            // NSTextView's minimum frame can fill the viewport for short files.
            // Add space after the actual final line, not after that minimum frame.
            contentHeight = lastLine.maxY + editor.textContainerOrigin.y + editor.textContainerInset.height
            // Stretching beyond EOF can temporarily leave TextKit's viewport
            // empty. Keep the measured extent instead of growing it mid-bounce.
            measuredTail = (ObjectIdentifier(editor), editor.textEditGeneration, editor.frame.width,
                            editor.styleKey, contentHeight, tailHeight)
        }
        // Include AppKit's accessory inset and the text view's own bottom padding
        // so the maximum scroll position aligns the final line with the top.
        let accessoryInset = max(0, contentView.contentInsets.bottom)
        let bottomSpace = max(0, contentView.bounds.height - tailHeight - accessoryInset)
        let scrollableHeight = contentHeight + bottomSpace
        if let clip = contentView as? EditorBounceClipView, clip.scrollableDocumentHeight != scrollableHeight {
            clip.scrollableDocumentHeight = scrollableHeight
            reflectScrolledClipView(clip)
        }
    }
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let panel = (documentView as? NativeManuscriptTextView)?.inlinePanel { children.append(panel) }
        return children
    }
    init(textView: NativeManuscriptTextView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        contentView = EditorBounceClipView(frame: contentView.frame)
        verticalScrollElasticity = .none
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        documentView = textView
        verticalRulerView = NativeManuscriptRuler(scrollView: self)
        hasVerticalRuler = true
        rulersVisible = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Inline presentation changes attributes only; source offsets, newlines and Undo stay native.
