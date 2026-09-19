import AppKit

/// NSTextView owns input, selection, key bindings and undo. Only manuscript commands
/// and the line-number accessory are app-specific. TextKit 2 owns viewport layout.
final class NativeManuscriptTextView: NSTextView, NSTextLayoutManagerDelegate, EditorToolTarget {
    lazy var toolBridge = EditorToolBridge(editor: self)
    lazy var scrollCoordinator = EditorScrollCoordinator(editor: self)
    private var displayStyle: EditorDisplayStyle?
    private let markdownPresentation = MarkdownPresentationController()
    private var trackingMouseSelection = false

    // AppKit runs its mouse tracking loop inside mouseDown. The presentation
    // controller must not change marker geometry underneath its hit testing.
    override func mouseDown(with event: NSEvent) {
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
    private(set) var inlinePanel: NSView?
    private var inlineAnchor = 0
    private let inlineTopMargin: CGFloat = 8
    private var inlineHeight: CGFloat { 100 + inlineTopMargin }

    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    @objc func undo(_ sender: Any?) { commitComposition(); undoManager?.undo() }
    @objc func redo(_ sender: Any?) { commitComposition(); undoManager?.redo() }
    var lineStarts = [0]
    private var lineIndexNeedsUpdate = true
    private var storageEditObserver: NSObjectProtocol?
    private(set) var lastIndexedUTF16Count = 0
    fileprivate private(set) var textEditGeneration = 0
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
            self.updateLineIndex(storage)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let storageEditObserver { NotificationCenter.default.removeObserver(storageEditObserver) }
    }

    /// Rescan only the edited paragraphs, including neighbors for CRLF joins/splits.
    /// Storage notifications include Undo and IME edits as well as toolbar commands.
    private func updateLineIndex(_ storage: NSTextStorage) {
        guard !lineIndexNeedsUpdate else { return }
        let range = storage.editedRange
        let delta = storage.changeInLength
        let oldEnd = NSMaxRange(range) - delta
        let first = line(at: max(0, range.location - 1))
        let suffix = min(lineStarts.count, line(at: oldEnd) + 2)
        let start = lineStarts[first]
        let end = suffix < lineStarts.count ? lineStarts[suffix] + delta : storage.length
        guard start <= end, end <= storage.length else { lineIndexNeedsUpdate = true; return }
        let value = storage.attributedSubstring(from: NSRange(location: start, length: end - start)).string as NSString
        lastIndexedUTF16Count = value.length
        var replacement = [start]
        var offset = 0
        while offset < value.length {
            let next = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < value.length { replacement.append(start + next) }
            else if suffix == lineStarts.count, let scalar = UnicodeScalar(value.character(at: value.length - 1)),
                    CharacterSet.newlines.contains(scalar) { replacement.append(start + next) }
            offset = next
        }
        // No text scan or allocation of the untouched manuscript suffix.
        if delta != 0 {
            for index in suffix..<lineStarts.count { lineStarts[index] += delta }
        }
        lineStarts.replaceSubrange(first..<suffix, with: replacement)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func rebuildLineIndex() {
        guard lineIndexNeedsUpdate else { return }
        lineIndexNeedsUpdate = false
        let value = string as NSString
        lastIndexedUTF16Count = value.length
        var starts = [0]
        var offset = 0
        while offset < value.length {
            let next = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < value.length { starts.append(next) }
            else if value.length > 0, let scalar = UnicodeScalar(value.character(at: value.length - 1)), CharacterSet.newlines.contains(scalar) {
                starts.append(next)
            }
            offset = next
        }
        lineStarts = starts
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
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
        lineIndexNeedsUpdate = true
        if let prepared, prepared.text == value, let content = textContentStorage,
           let storage = prepared.takeStorage() {
            content.textStorage = storage
            typingAttributes = prepared.typingAttributes
            defaultParagraphStyle = prepared.typingAttributes[.paragraphStyle] as? NSParagraphStyle
            styleKey = prepared.styleKey
            lineStarts = prepared.lineStarts
            lineIndexNeedsUpdate = false
            lastIndexedUTF16Count = 0
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

    func runTool(_ definition: EditorToolDefinition) {
        let effects: EditorToolDescriptor.Effects
        let category: EditorToolDescriptor.Category
        switch definition.impact {
        case .text: effects = [.text, .selection, .layout]; category = .documentEdit
        case .selection: effects = [.selection, .layout]; category = .navigation
        case .presentation: effects = []; category = .presentation
        case .request: effects = []; category = .assistant
        }
        toolBridge.perform(.init(name: definition.id, category: category, effects: effects)) {
            let generation = self.textEditGeneration
            let selection = self.selectedRange()
            let panel = self.inlinePanel
            definition.operation(self)
            return generation != self.textEditGeneration || selection != self.selectedRange() || panel !== self.inlinePanel
                || definition.impact == .request || definition.impact == .presentation
        }
    }
    func toolFormat(_ kind: String) {
        let formats: [String: MarkdownFormatType] = ["bold": .bold, "italic": .italic, "boldItalic": .boldItalic,
                                                    "underline": .underline, "strikethrough": .strikethrough]
        if let format = formats[kind] { applyCommand(EditorCommand(.format(format))) }
    }
    func toolAssistant(_ titleKey: String) {
        if titleKey == "collaboration.commentSelection" {
            NotificationCenter.default.post(name: .init("collaborationCommentRequested"), object: nil)
        } else { applyCommand(EditorCommand(.assistantDraft(L10n.get(titleKey)))) }
    }
    func toolPresent(_ control: String) { onToolPresentation?(control) }
    func toolAttachSelection() {
        guard selectedRange().length > 0 else { return }
        let text = textStorage?.attributedSubstring(from: selectedRange()).string ?? ""
        NotificationCenter.default.post(name: Notification.Name("aiAttachSelection"), object: text)
    }

    func execute(_ command: EditorCommand) {
        if case .tool(let id) = command.action { EditorToolRegistry.perform(id, on: self); return }
        toolBridge.perform(command.tool) {
            let generation = self.textEditGeneration
            let selection = self.selectedRange()
            self.applyCommand(command)
            return generation != self.textEditGeneration || selection != self.selectedRange() || command.tool.category == .assistant
        }
    }

    private func applyCommand(_ command: EditorCommand) {
        switch command.action {
        case .tool: return
        case .assistantDraft(let action):
            NotificationCenter.default.post(name: Notification.Name("aiDraftAction"), object: action)
            return
        case .locate(let line, let query):
            let start = offset(line: line, column: 0)
            let source = string as NSString
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let match = source.range(of: query, options: .caseInsensitive, range: lineRange)
            setSelectedRange(match.location == NSNotFound ? NSRange(location: start, length: 0) : match)
        case .find(let query, let forward): find(query, forward: forward)
        case .replace(let query, let replacement, let all):
            guard !query.isEmpty, isEditable else { return }
            if all {
                let result = string.replacingOccurrences(of: query, with: replacement)
                if result != string { replace(NSRange(location: 0, length: (textStorage?.length ?? 0)), with: result) }
            } else {
                if (string as NSString).substring(with: selectedRange()) != query { find(query, forward: true) }
                if (string as NSString).substring(with: selectedRange()) == query { replace(selectedRange(), with: replacement) }
            }
        case .format(let type):
            guard selectedRange().length > 0 else { return }
            let markers: (String, String)
            switch type {
            case .bold: markers = ("**", "**")
            case .italic: markers = ("*", "*")
            case .boldItalic: markers = ("***", "***")
            case .underline: markers = ("<u>", "</u>")
            case .strikethrough: markers = ("~~", "~~")
            }
            let selected = textStorage?.attributedSubstring(from: selectedRange()).string ?? ""
            let result = selected.hasPrefix(markers.0) && selected.hasSuffix(markers.1) && selected.count >= markers.0.count + markers.1.count
                ? String(selected.dropFirst(markers.0.count).dropLast(markers.1.count)) : markers.0 + selected + markers.1
            replace(selectedRange(), with: result, selectReplacement: true)
        }
        scrollCoordinator.revealSelection()
    }
    private func find(_ query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        let value = string as NSString
        let selection = selectedRange()
        let offset = forward ? NSMaxRange(selection) : selection.location
        let first = forward ? NSRange(location: offset, length: value.length - offset) : NSRange(location: 0, length: offset)
        let options: NSString.CompareOptions = forward ? [] : [.backwards]
        var match = value.range(of: query, options: options, range: first)
        if match.location == NSNotFound { match = value.range(of: query, options: options) }
        if match.location != NSNotFound { setSelectedRange(match) }
    }
    /// All geometry is in the TextKit 2 container coordinate system. Never access
    /// NSTextView.layoutManager: that would silently enable TextKit 1 compatibility.
    func textLocation(at offset: Int) -> (any NSTextLocation)? {
        guard let content = textLayoutManager?.textContentManager else { return nil }
        return content.location(content.documentRange.location, offsetBy: min(max(0, offset), textStorage?.length ?? 0))
    }

    private func layoutFragment(at location: any NSTextLocation) -> NSTextLayoutFragment? {
        guard let manager = textLayoutManager else { return nil }
        if let fragment = manager.textLayoutFragment(for: location) { return fragment }
        // Empty documents / trailing empty paragraphs have a zero-length fragment.
        // A location lookup can miss it; enumeration includes that cached fragment.
        var result: NSTextLayoutFragment?
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresExtraLineFragment]) { fragment in
            result = fragment
            return false
        }
        if result == nil, let content = manager.textContentManager,
           location.compare(content.documentRange.endLocation) == .orderedSame,
           let previous = content.location(location, offsetBy: -1) {
            result = manager.textLayoutFragment(for: previous)
        }
        return result
    }

    func lineRect(at offset: Int) -> NSRect? {
        guard let location = textLocation(at: offset),
              let fragment = layoutFragment(at: location),
              fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false)
                ?? (offset == textStorage?.length ? fragment.textLineFragments.last : nil) else { return nil }
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                               dy: fragment.layoutFragmentFrame.minY)
    }

    /// Enumerate only already-laid-out viewport fragments; accessories never lay out
    /// the entire document just to obtain line numbers or selection backgrounds.
    func visibleManuscriptLines() -> [(row: Int, rect: NSRect)] {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        var lines: [(row: Int, rect: NSRect)] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            // Unlaid-out fragments have zero geometry. Testing their Y coordinate
            // alone walks to EOF and materializes the rest of a large document.
            // Bound traversal by text locations before reading any geometry.
            guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending,
                  fragment.state == .layoutAvailable else { return false }
            guard fragment.layoutFragmentFrame.minY <= visible.maxY else { return false }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let offset = start + lineFragment.characterRange.location
                let row = self.line(at: offset)
                // Soft-wrapped continuation lines have no separate manuscript number.
                guard self.lineStarts[row] == offset else { continue }
                let frame = lineFragment.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                                    dy: fragment.layoutFragmentFrame.minY)
                if frame.maxY >= visible.minY && frame.minY <= visible.maxY { lines.append((row, frame)) }
            }
            return true
        }
        return lines
    }

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

    func installInlinePanel(_ panel: NSView) {
        closeInlinePanel()
        let source = string as NSString
        let selection = selectedRange()
        let end = min(source.length, selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location)
        let lineRange = source.lineRange(for: NSRange(location: end, length: 0))
        inlineAnchor = lineRange.length == 0 ? source.length : NSMaxRange(lineRange) - 1
        inlinePanel = panel
        addSubview(panel)
        invalidateInlineLayout()
        scrollCoordinator.reveal(panel.frame)
    }

    func closeInlinePanel() {
        guard let panel = inlinePanel else { return }
        panel.removeFromSuperview()
        inlinePanel = nil
        invalidateInlineLayout()
    }

    private func invalidateInlineLayout() {
        guard let manager = textLayoutManager,
              let location = textLocation(at: inlineAnchor) else { return }
        // Invalidating the anchor paragraph refreshes its custom fragment and reflows
        // following viewport fragments without changing the manuscript or undo stack.
        let fragment = layoutFragment(at: location)
        if let custom = fragment as? ManuscriptLayoutFragment {
            custom.panelHeight = inlinePanel == nil ? 0 : inlineHeight
            custom.invalidateLayout()
        }
        let range = fragment?.rangeInElement ?? NSTextRange(location: location)
        manager.invalidateLayout(for: range)
        manager.ensureLayout(for: range)
        manager.textViewportLayoutController.layoutViewport()
        needsLayout = true
        layoutSubtreeIfNeeded()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        needsDisplay = true
    }

    typealias CursorViewportAnchor = EditorScrollCoordinator.Anchor
    func captureCursorViewportAnchor() -> CursorViewportAnchor? { scrollCoordinator.capture(.followCursor) }
    func restoreCursorViewportAnchor(_ anchor: CursorViewportAnchor) { scrollCoordinator.restore(anchor) }

    func applyDisplayStyle(_ style: EditorDisplayStyle) {
        guard style.key != styleKey else { displayStyle = style; return }
        toolBridge.perform(.init(name: "displayStyle", category: .presentation, effects: [.layout])) {
            let delta = style.changedAttributes(from: self.displayStyle)
            self.textContentStorage?.performEditingTransaction {
                self.textStorage?.beginEditing()
                self.textStorage?.addAttributes(delta, range: NSRange(location: 0, length: self.textStorage?.length ?? 0))
                self.textStorage?.endEditing()
            }
            self.typingAttributes.merge(delta) { _, new in new }
            if let paragraph = delta[.paragraphStyle] as? NSParagraphStyle { self.defaultParagraphStyle = paragraph }
            self.displayStyle = style
            self.styleKey = style.key
            self.refreshMarkdownRendering()
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
        guard let panel = inlinePanel,
              let location = textLocation(at: inlineAnchor),
              let fragment = layoutFragment(at: location),
              fragment.state == .layoutAvailable else { return }
        let y = fragment.layoutFragmentFrame.maxY - inlineHeight + inlineTopMargin + textContainerOrigin.y
        // The document view may temporarily retain a wider frame during split-view
        // animation. Size against the clip view, not the manuscript's content width.
        let viewport = enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) } ?? bounds
        let inset = textContainerOrigin.x
        var left = viewport.minX
        if let scroll = enclosingScrollView, scroll.rulersVisible,
           let ruler = scroll.verticalRulerView, !ruler.isHidden {
            // Rulers may overlap the clip view. Convert their actual boundary into
            // manuscript coordinates rather than assuming the clip width excludes it.
            let rulerFrame = convert(ruler.bounds, from: ruler)
            left = max(left, min(viewport.maxX, rulerFrame.maxX))
        }
        panel.frame = NSRect(x: left + inset, y: y,
                             width: max(0, viewport.maxX - left - 2 * inset), height: inlineHeight - inlineTopMargin - 8)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = ManuscriptLayoutFragment(textElement: textElement, range: textElement.elementRange)
        if inlinePanel != nil, let content = textLayoutManager.textContentManager,
           let range = textElement.elementRange {
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let end = content.offset(from: content.documentRange.location, to: range.endLocation)
            if inlineAnchor >= start && (inlineAnchor < end || (inlineAnchor == end && end == (textStorage?.length ?? 0))) {
                fragment.panelHeight = inlineHeight
            }
        }
        return fragment
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if inlinePanel != nil, let replacementString {
            if NSMaxRange(affectedCharRange) <= inlineAnchor {
                inlineAnchor += replacementString.utf16.count - affectedCharRange.length
            } else if affectedCharRange.location <= inlineAnchor {
                inlineAnchor = affectedCharRange.location + replacementString.utf16.count
            }
        }
        return true
    }

    override func didChangeText() {
        textEditGeneration &+= 1
        super.didChangeText()
        refreshMarkdownRendering()
        if inlinePanel != nil {
            inlineAnchor = min(max(0, inlineAnchor), (textStorage?.length ?? 0))
            invalidateInlineLayout()
        }
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

/// Presentation-only paragraph spacing: no attachment characters enter saved text.
private final class ManuscriptLayoutFragment: NSTextLayoutFragment {
    var panelHeight: CGFloat = 0
    override var bottomMargin: CGFloat { super.bottomMargin + panelHeight }
}

/// Global ruler geometry, independent of each document's typography overrides.
enum EditorRulerAppearance {
    static let store = UserDefaults(suiteName: "com.loreweave.settings") ?? .standard
    static let widthKey = "editorRuler.width"
    static let defaultWidth = 58.0
    static let widthRange = 40.0...120.0
    static func bounded(_ width: Double) -> Double {
        width.isFinite ? min(widthRange.upperBound, max(widthRange.lowerBound, width)) : defaultWidth
    }
}

final class NativeManuscriptRuler: NSRulerView {
    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = EditorRulerAppearance.bounded(EditorRulerAppearance.store.object(forKey: EditorRulerAppearance.widthKey) as? Double ?? EditorRulerAppearance.defaultWidth)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = scrollView?.documentView as? NativeManuscriptTextView else { return }
        view.backgroundColor.setFill(); bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for (row, fragment) in view.visibleManuscriptLines() {
            let point = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            let label = "\(row + 1)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8, y: point.y + max(0, (fragment.height - label.size(withAttributes: attributes).height) / 2)), withAttributes: attributes)
            if view.modifiedLines.contains(row) {
                NSColor.systemOrange.setFill()
                NSRect(x: 2, y: point.y, width: 3, height: max(12, fragment.height)).fill()
            }
        }
    }
}

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
