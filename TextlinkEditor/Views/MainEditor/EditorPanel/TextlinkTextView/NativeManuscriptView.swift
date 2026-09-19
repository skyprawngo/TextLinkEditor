import AppKit

/// NSTextView owns input, selection, key bindings and undo. Only manuscript commands
/// and the line-number accessory are app-specific. TextKit 2 owns viewport layout.
final class NativeManuscriptTextView: NSTextView, NSTextLayoutManagerDelegate, EditorToolTarget {
    lazy var toolBridge = EditorToolBridge(editor: self)
    lazy var presentationCoordinator = ManuscriptPresentationCoordinator(editor: self)
    lazy var scrollCoordinator = EditorScrollCoordinator(editor: self)
    private var displayStyle: EditorDisplayStyle?
    private let markdownPresentation = MarkdownPresentationController()
    private var trackingMouseSelection = false

    // AppKit runs its mouse tracking loop inside mouseDown. The presentation
    // controller must not change marker geometry underneath its hit testing.
    override func mouseDown(with event: NSEvent) {
        EditorFocusCoordinator.claimEditor(in: window)
        trackingMouseSelection = true
        defer {
            trackingMouseSelection = false
            refreshMarkdownRendering()
        }
        super.mouseDown(with: event)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard range.length == 0, let scroll = enclosingScrollView,
              let line = lineRect(at: range.location) else {
            super.scrollRangeToVisible(range)
            return
        }
        let clip = scroll.contentView
        let rect = line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let top = clip.bounds.minY + clip.contentInsets.top
        let bottom = clip.bounds.maxY - clip.contentInsets.bottom
        var point = clip.bounds.origin
        if rect.minY < top { point.y += rect.minY - top }
        else if rect.maxY > bottom { point.y += rect.maxY - bottom }
        guard point != clip.bounds.origin else { return }
        clip.scroll(to: point)
        scroll.reflectScrolledClipView(clip)
    }

    func setMarkdownRendering(_ enabled: Bool) {
        markdownPresentation.setMarkdownRendering(enabled, editor: self, style: displayStyle, generation: textEditGeneration)
    }

    func refreshMarkdownRendering(reset: Bool = false) {
        markdownPresentation.refresh(editor: self, style: displayStyle, generation: textEditGeneration, reset: reset, trackingSelection: trackingMouseSelection)
    }
    private lazy var inlinePresentation = ManuscriptInlinePanelController(editor: self)
    var inlinePanel: NSView? { inlinePresentation.panel }

    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    @objc func undo(_ sender: Any?) { commitComposition(); undoManager?.undo() }
    @objc func redo(_ sender: Any?) { commitComposition(); undoManager?.redo() }
    private var lineIndex = ManuscriptLineIndex()
    var lineStarts: [Int] { lineIndex.starts }
    private var storageEditObserver: NSObjectProtocol?
    var lastIndexedUTF16Count: Int { lineIndex.lastScannedUTF16Count }
    private(set) var textEditGeneration = 0
    var styleKey = ""
    var modifiedLines: Set<Int> = []

    init() {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        layout.delegate = self
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 8, height: 8)
        usesFindPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        backgroundColor = AppColors.nsTextEditorBackground
        insertionPointColor = AppColors.nsEditorCursor
        textColor = AppColors.nsEditorText
        storageEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let storage = notification.object as? NSTextStorage,
                  storage === self.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
            self.lineIndex.update(storage)
            self.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let storageEditObserver { NotificationCenter.default.removeObserver(storageEditObserver) }
    }

    func rebuildLineIndex() {
        guard lineIndex.needsRebuild else { return }
        lineIndex.rebuild(string)
    }
    func line(at offset: Int) -> Int { lineIndex.line(at: offset) }
    func position(at offset: Int) -> (line: Int, column: Int) {
        let offset = min(max(0, offset), textStorage?.length ?? 0)
        let row = line(at: offset)
        let prefix = textStorage?.attributedSubstring(from: NSRange(location: lineStarts[row], length: offset - lineStarts[row])).string ?? ""
        return (row, prefix.count)
    }
    func offset(line: Int, column: Int) -> Int {
        let row = min(max(0, line), lineStarts.count - 1)
        let value = string as NSString
        let start = lineStarts[row]
        var end = row + 1 < lineStarts.count ? lineStarts[row + 1] : value.length
        while end > start, let scalar = UnicodeScalar(value.character(at: end - 1)), CharacterSet.newlines.contains(scalar) { end -= 1 }
        let content = value.substring(with: NSRange(location: start, length: end - start))
        return start + content.prefix(max(0, column)).utf16.count
    }
    func commitComposition() {
        if hasMarkedText() { unmarkText(); inputContext?.discardMarkedText() }
        breakUndoCoalescing()
    }
    func load(_ value: String, prepared: PreparedManuscript? = nil) {
        markdownPresentation.invalidate()
        toolBridge.cancelPending()
        scrollCoordinator.cancel()
        displayStyle = nil
        closeInlinePanel()
        commitComposition()
        lineIndex.invalidate()
        if let prepared, prepared.text == value, let content = textContentStorage,
           let storage = prepared.takeStorage() {
            content.textStorage = storage
            typingAttributes = prepared.typingAttributes
            defaultParagraphStyle = prepared.typingAttributes[.paragraphStyle] as? NSParagraphStyle
            styleKey = prepared.styleKey
            lineIndex.adopt(prepared.lineStarts)
        } else {
            string = value
            styleKey = ""
        }
        undoManager?.removeAllActions()
        rebuildLineIndex()
    }
    /// Disk reloads and AI edits preserve the first visible text line, independent of the caret.
    func applyExternalText(_ value: String, prepared: PreparedManuscript? = nil, undoable: Bool = false) {
        let original = string
        guard original != value else { return }
        let oldLength = original.utf16.count
        let newLength = value.utf16.count
        var prefix = 0
        for (old, new) in zip(original, value) {
            guard old == new else { break }
            prefix += String(old).utf16.count
        }
        var suffix = 0
        for (old, new) in zip(original.reversed(), value.reversed()) {
            let count = String(old).utf16.count
            guard old == new, suffix + count <= min(oldLength, newLength) - prefix else { break }
            suffix += count
        }
        func mapped(_ offset: Int) -> Int {
            if offset <= prefix { return offset }
            if offset >= oldLength - suffix { return max(0, offset + newLength - oldLength) }
            return prefix + min(offset - prefix, newLength - prefix - suffix)
        }
        let selection = selectedRange()
        let style = displayStyle
        let anchor = scrollCoordinator.capture(for: .externalTextChange).map {
            CursorViewportAnchor(offset: mapped($0.offset), screenY: $0.screenY)
        }
        if undoable {
            let replacement = (value as NSString).substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
            replace(NSRange(location: prefix, length: oldLength - prefix - suffix), with: replacement)
        } else {
            load(value, prepared: prepared)
            if let style { applyDisplayStyle(style) }
        }
        let start = mapped(min(selection.location, oldLength))
        let end = mapped(min(NSMaxRange(selection), oldLength))
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        if let anchor { scrollCoordinator.restore(anchor) }
        needsLayout = true
        needsDisplay = true
    }

    func replace(_ range: NSRange, with replacement: String, selectReplacement: Bool = false) {
        guard isEditable, shouldChangeText(in: range, replacementString: replacement) else { return }
        breakUndoCoalescing()
        textContentStorage?.performEditingTransaction {
            textStorage?.replaceCharacters(in: range, with: replacement)
        }
        didChangeText()
        setSelectedRange(NSRange(location: selectReplacement ? range.location : range.location + replacement.utf16.count,
                                 length: selectReplacement ? replacement.utf16.count : 0))
    }
    var onToolPresentation: ((String) -> Void)?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0,
              let viewport = textLayoutManager?.textViewportLayoutController.viewportRange,
              let location = textLocation(at: selectedRange().location),
              location.compare(viewport.location) != .orderedAscending,
              location.compare(viewport.endLocation) != .orderedDescending,
              var lineRect = lineRect(at: selectedRange().location) else { return }
        lineRect.origin.y += textContainerOrigin.y
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        if lineRect.intersects(rect) { AppColors.nsCurrentLineHighlight.setFill(); lineRect.intersection(rect).fill() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let responder = window?.firstResponder as? NSView
        let inlineFocused = inlinePanel.map { responder?.isDescendant(of: $0) == true } ?? false
        if let action = KeyboardShortcutManager.shared.action(matching: event),
           window?.firstResponder === self || (inlineFocused && action.rawValue == "ai.inline"),
           EditorToolRegistry.perform(action.rawValue, on: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if let action = KeyboardShortcutManager.shared.action(matching: event) {
            if EditorToolRegistry.perform(action.rawValue, on: self) { return }
            switch action {
            case .deleteWordBackward: deleteWordBackward(nil); return
            case .deleteToLineStart: deleteToBeginningOfLine(nil); return
            case .moveLineUp, .moveLineDown, .duplicateLineUp, .duplicateLineDown:
                guard isEditable else { return }
                commitComposition()
                let state = EditorState(text: string)
                let range = selectedRange()
                state.selection.select(from: state.document.positionFromUTF16Offset(range.location),
                                       to: state.document.positionFromUTF16Offset(NSMaxRange(range)))
                let changed: Bool
                switch action {
                case .moveLineUp: changed = state.moveLineUp()
                case .moveLineDown: changed = state.moveLineDown()
                case .duplicateLineUp: changed = state.duplicateLineUp()
                default: changed = state.duplicateLineDown()
                }
                if changed {
                    replace(NSRange(location: 0, length: (textStorage?.length ?? 0)), with: state.getText())
                    let selection = state.selection.range.normalized
                    let start = state.document.utf16Offset(from: selection.start)
                    setSelectedRange(NSRange(location: start, length: state.document.utf16Offset(from: selection.end) - start))
                    scrollCoordinator.revealSelection()
                }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for (index, key) in ["editor.bold", "editor.italic", "editor.underline", "editor.strikethrough"].enumerated() {
            let item = NSMenuItem(title: L10n.get(key), action: #selector(formatSelection(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            menu.addItem(item)
        }
        let attach = NSMenuItem(title: L10n.get("ai.context.attachSelection"), action: #selector(attachSelectionToAI(_:)), keyEquivalent: "")
        attach.target = self
        menu.addItem(attach)
        let comment = NSMenuItem(title: L10n.get("collaboration.commentSelection"), action: #selector(commentSelection(_:)), keyEquivalent: "")
        comment.target = self
        menu.addItem(comment)
        let inline = NSMenuItem(title: L10n.get("ai.inline.open"), action: #selector(openInlineAI(_:)), keyEquivalent: "")
        inline.target = self
        menu.addItem(inline)
        return menu
    }
    @objc private func openInlineAI(_ sender: Any?) { EditorToolRegistry.perform("ai.inline", on: self) }
    func toolToggleInline() {
        if inlinePanel != nil {
            closeInlinePanel()
            window?.makeFirstResponder(self)
            return
        }
        guard isEditable else { return }
        commitComposition()
        NotificationCenter.default.post(name: Notification.Name("editorInlineAI"), object: self)
    }

    func installInlinePanel(_ panel: NSView) { inlinePresentation.install(panel) }
    func closeInlinePanel() { inlinePresentation.close() }

    typealias CursorViewportAnchor = EditorScrollCoordinator.Anchor
    func captureCursorViewportAnchor() -> CursorViewportAnchor? { scrollCoordinator.capture(.followCursor) }
    func restoreCursorViewportAnchor(_ anchor: CursorViewportAnchor) { scrollCoordinator.restore(anchor) }

    func applyDisplayStyle(_ style: EditorDisplayStyle) {
        guard style.key != styleKey else { displayStyle = style; return }
        toolBridge.perform(.init(name: "displayStyle", category: .presentation, effects: [.layout]), preservesCursor: false) {
            let delta = style.changedAttributes(from: self.displayStyle)
            self.presentationCoordinator.perform(for: .appearanceChange) {
                self.textStorage?.beginEditing()
                self.textStorage?.addAttributes(delta, range: NSRange(location: 0, length: self.textStorage?.length ?? 0))
                self.textStorage?.endEditing()
                self.typingAttributes.merge(delta) { _, new in new }
                if let paragraph = delta[.paragraphStyle] as? NSParagraphStyle { self.defaultParagraphStyle = paragraph }
                self.displayStyle = style
                self.styleKey = style.key
                self.refreshMarkdownRendering()
            }
            return true
        }
    }

    // Window resizing preserves the viewport; presentation tools preserve the cursor line.
    private var restoringResizeAnchor = false
    override func setFrameSize(_ newSize: NSSize) {
        let anchor = !restoringResizeAnchor && newSize.width != frame.width ? scrollCoordinator.captureResizeAnchor() : nil
        guard let anchor else { super.setFrameSize(newSize); return }
        restoringResizeAnchor = true
        defer { restoringResizeAnchor = false }
        super.setFrameSize(newSize)
        scrollCoordinator.restoreResizeAnchor(anchor)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            toolBridge.cancelPending()
            scrollCoordinator.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        defer { toolBridge.viewportDidLayout() }
        super.layout()
        (enclosingScrollView as? NativeManuscriptHost)?.updateBottomScrollSpace()
        scrollCoordinator.layoutDidFinish()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        inlinePresentation.layout()
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        inlinePresentation.makeFragment(for: textElement, manager: textLayoutManager)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if let replacementString { inlinePresentation.willReplace(affectedCharRange, with: replacementString) }
        return true
    }

    override func didChangeText() {
        textEditGeneration &+= 1
        super.didChangeText()
        refreshMarkdownRendering()
        inlinePresentation.textDidChange()
    }

    @objc private func attachSelectionToAI(_ sender: Any?) { EditorToolRegistry.perform("ai.attachSelection", on: self) }
    @objc private func commentSelection(_ sender: Any?) { EditorToolRegistry.perform("ai.collaborationComment", on: self) }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openInlineAI(_:)) { return isEditable }
        if menuItem.action == #selector(attachSelectionToAI(_:)) { return selectedRange().length > 0 }
        if menuItem.action == #selector(commentSelection(_:)) { return selectedRange().length > 0 && !hasMarkedText() }
        if menuItem.action == #selector(undo(_:)) { return isEditable && documentUndoManager.canUndo }
        if menuItem.action == #selector(redo(_:)) { return isEditable && documentUndoManager.canRedo }
        if menuItem.action == #selector(formatSelection(_:)) { return isEditable && selectedRange().length > 0 }
        return super.validateMenuItem(menuItem)
    }
    @objc private func formatSelection(_ sender: NSMenuItem) {
        let types: [MarkdownFormatType] = [.bold, .italic, .underline, .strikethrough]
        guard types.indices.contains(sender.tag) else { return }
        EditorToolRegistry.perform("format.\(types[sender.tag])", on: self)
    }
}
