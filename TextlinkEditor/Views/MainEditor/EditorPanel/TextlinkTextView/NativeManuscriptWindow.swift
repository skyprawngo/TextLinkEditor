import AppKit

/// Projects a paragraph window into TextKit; document positions survive window eviction.
final class ManuscriptWindowController {
    let document: ManuscriptWindowDocument
    let undoManager = UndoManager()
    private weak var editor: NativeManuscriptTextView?
    private(set) var range: NSRange
    private(set) var installing = false
    private(set) var transitionCount = 0
    private(set) var insertedUTF16Count = 0
    private var observer: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var fullSelection: NSRange?
    var hasVirtualSelection: Bool { fullSelection != nil }
    var firstRow: Int { document.line(at: range.location) }
    var selectedRange: NSRange {
        fullSelection ?? NSRange(location: range.location + (editor?.selectedRange().location ?? 0), length: editor?.selectedRange().length ?? 0)
    }

    init(editor: NativeManuscriptTextView, document: ManuscriptWindowDocument) {
        self.editor = editor; self.document = document; range = document.range(around: 0)
        undoManager.groupsByEvent = false
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: editor.textStorage, queue: nil) { [weak self] notification in
            guard let self, self.editor?.windowedDocument === self, !self.installing, let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            let edited = storage.editedRange
            let global = NSRange(location: self.range.location + edited.location, length: edited.length - storage.changeInLength)
            let replacement = storage.attributedSubstring(from: edited).string
            let old = self.document.replace(global, with: replacement)
            self.range.length += storage.changeInLength
            self.fullSelection = nil
            self.registerUndo(range: NSRange(location: global.location, length: replacement.utf16.count), text: old)
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
    func deactivate() {
        endComposition()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        observer = nil
        scrollObserver = nil
        undoManager.removeAllActions()
    }
    func attach(to host: NativeManuscriptHost) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        host.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: host.contentView, queue: .main) { [weak self, weak host] _ in
            guard let self, let editor = self.editor, host?.documentView === editor,
                  editor.windowedDocument === self else { return }
            self.extendIfNeeded()
        }
    }
    private func registerUndo(range: NSRange, text: String) {
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in target.replace(range, with: text) }
        if needsGroup { undoManager.endUndoGrouping() }
    }
    private var composing = false
    func beginComposition() {
        guard !composing else { return }
        composing = true
        undoManager.beginUndoGrouping()
    }
    func endComposition() {
        guard composing else { return }
        composing = false
        undoManager.endUndoGrouping()
    }
    func replace(_ edit: NSRange, with text: String) {
        guard let editor, editor.isEditable else { return }
        editor.commitComposition()
        editor.documentWillReplace(edit, with: text)
        let old = document.replace(edit, with: text)
        registerUndo(range: NSRange(location: edit.location, length: text.utf16.count), text: old)
        fullSelection = nil
        install(document.range(around: edit.location + text.utf16.count), selection: NSRange(location: edit.location + text.utf16.count, length: 0), anchor: nil, force: true)
        editor.didChangeText()
        editor.scrollCoordinator.revealSelection()
    }
    func prepareForInput() {
        guard let editor, !editor.hasMarkedText() else { return }
        let selection = selectedRange
        if selection.length == 0 {
            let next = document.range(around: selection.location)
            if next != range {
                let anchor = editor.scrollCoordinator.capture(.preserveViewport).map {
                    EditorScrollCoordinator.Anchor(offset: $0.offset + range.location, screenY: $0.screenY)
                }
                let contained = anchor.map { $0.offset >= next.location && $0.offset <= NSMaxRange(next) } ?? false
                install(next, selection: selection, anchor: contained ? anchor : nil)
                if !contained { editor.scrollCoordinator.revealSelection() }
            }
        }
    }
    func clearVirtualSelection() { fullSelection = nil }
    func select(_ selection: NSRange, reveal: Bool = true, focus: Int? = nil) {
        guard let editor else { return }
        let previousSelection = selectedRange
        let start = min(document.length, max(0, selection.location))
        let selection = NSRange(location: start, length: min(selection.length, document.length - start))
        let focus = min(document.length, max(0, focus ?? selection.location))
        if (reveal || selection.length == 0) && (focus < range.location || focus > NSMaxRange(range)) {
            install(document.range(around: focus), selection: selection, anchor: nil)
        }
        fullSelection = selection.location < range.location || NSMaxRange(selection) > NSMaxRange(range) ? selection : nil
        let localStart = min(range.length, max(0, selection.location - range.location))
        editor.setSelectedRange(NSRange(location: localStart, length: max(0, min(NSMaxRange(selection), NSMaxRange(range)) - max(selection.location, range.location))))
        if reveal {
            editor.scrollRangeToVisible(NSRange(location: min(range.length, max(0, focus - range.location)), length: 0))
        }
        if previousSelection != selectedRange {
            editor.delegate?.textViewDidChangeSelection?(Notification(name: NSTextView.didChangeSelectionNotification, object: editor))
        }
    }
    func extendIfNeeded(whileSelecting: Bool = false) {
        guard !installing, let editor, !editor.hasMarkedText(), !editor.presentationCoordinator.isApplying,
              (!editor.isTrackingManuscriptSelection || whileSelecting),
              let anchor = editor.scrollCoordinator.capture(.preserveViewport) else { return }
        let global = range.location + anchor.offset
        let row = document.line(at: global), first = firstRow
        let end = document.line(at: NSMaxRange(range))
        guard (row < first + ManuscriptWindowPolicy.prefetchLines && range.location > 0) || (row > end - ManuscriptWindowPolicy.prefetchLines && NSMaxRange(range) < document.length) else { return }
        let next = document.range(around: global)
        guard next != range else { return }
        install(next, selection: selectedRange, anchor: .init(offset: global, screenY: anchor.screenY))
    }
    func install(_ next: NSRange, selection: NSRange, anchor: EditorScrollCoordinator.Anchor?, force: Bool = false) {
        guard let editor, editor.windowedDocument === self, !installing else { return }
        installing = true
        defer {
            installing = false
            if let host = editor.enclosingScrollView { host.reflectScrolledClipView(host.contentView) }
        }
        let previous = range
        let overlap = NSIntersectionRange(previous, next)
        editor.toolBridge.cancelPending()
        editor.scrollCoordinator.cancel()
        editor.textContentStorage?.performEditingTransaction {
            guard let storage = editor.textStorage else { return }
            if force || overlap.length == 0 {
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: document.substring(next))
                insertedUTF16Count += next.length
            } else {
                // Keep the common text; remove/append only the difference, suffix before prefix.
                let oldSuffix = NSMaxRange(previous) - NSMaxRange(overlap)
                let newSuffix = NSRange(location: NSMaxRange(overlap), length: NSMaxRange(next) - NSMaxRange(overlap))
                storage.replaceCharacters(in: NSRange(location: NSMaxRange(overlap) - previous.location, length: oldSuffix), with: document.substring(newSuffix))
                let newPrefix = NSRange(location: next.location, length: overlap.location - next.location)
                storage.replaceCharacters(in: NSRange(location: 0, length: overlap.location - previous.location), with: document.substring(newPrefix))
                insertedUTF16Count += newPrefix.length + newSuffix.length
            }
        }
        range = next
        transitionCount += 1
        // An offscreen caret is document state, not a reason to scroll back to it.
        if selection.location < next.location || NSMaxRange(selection) > NSMaxRange(next) { fullSelection = selection }
        else { fullSelection = nil }
        let local = min(max(0, selection.location - next.location), next.length)
        editor.setSelectedRange(NSRange(location: local, length: max(0, min(NSMaxRange(selection), NSMaxRange(next)) - max(selection.location, next.location))))
        editor.didInstallWindow()
        if let anchor {
            editor.scrollCoordinator.restore(.init(offset: anchor.offset - next.location, screenY: anchor.screenY))
        }
        editor.layoutSubtreeIfNeeded()
        editor.updateInsertionPointStateAndRestartTimer(true)
    }
    func snapshot() -> EditorViewportPosition? {
        guard var value = editor?.scrollCoordinator.snapshot() else { return nil }
        value.firstVisibleLine += firstRow
        let cursor = document.position(selectedRange.location)
        value.cursorLine = cursor.line + 1
        value.cursorLineText = document.lineText(cursor.line)
        value.cursorOffsetWithinLine = cursor.column
        value.cursorTextBefore = String(document.lineText(cursor.line).prefix(cursor.column).suffix(24))
        value.cursorTextAfter = String(document.lineText(cursor.line).dropFirst(cursor.column).prefix(24))
        return value
    }
    func reopen(_ saved: EditorViewportPosition) {
        guard let editor else { return }
        let resolved = EditorViewportResolver.resolve(saved, lineCount: document.starts.count, lineText: document.lineText)
        let offset = document.starts[resolved.firstRow]
        let selection = resolved.cursorRow.map { NSRange(location: document.offset(line: $0, column: resolved.cursorColumn ?? 0), length: 0) } ?? selectedRange
        install(document.range(around: offset), selection: selection,
                anchor: .init(offset: offset, screenY: resolved.firstTextMatched && saved.offsetWithinLine.isFinite ? -CGFloat(saved.offsetWithinLine) : 0))
        editor.needsDisplay = true
    }
}

extension NativeManuscriptTextView {
    var documentText: String { windowedDocument?.document.text ?? string }
    var documentSelection: NSRange { windowedDocument?.selectedRange ?? selectedRange() }
    func documentPosition(at offset: Int) -> (line: Int, column: Int) { windowedDocument?.document.position(offset) ?? position(at: offset) }
    func loadDocument(_ value: String, prepared: PreparedManuscript? = nil) {
        commitComposition()
        windowedDocument?.deactivate()
        windowedDocument = nil
        allowsUndo = true
        let document = ManuscriptWindowDocument(value, starts: prepared?.text == value ? prepared?.lineStarts : nil)
        let initial = document.range(around: 0)
        load(document.substring(initial))
        setSelectedRange(NSRange(location: 0, length: 0))
        allowsUndo = false
        windowedDocument = ManuscriptWindowController(editor: self, document: document)
        if let host = enclosingScrollView as? NativeManuscriptHost { windowedDocument?.attach(to: host) }
    }
    func selectDocumentPosition(line: Int, column: Int) {
        if let windowedDocument {
            windowedDocument.select(NSRange(location: windowedDocument.document.offset(line: line, column: column), length: 0), reveal: false)
        } else { setSelectedRange(NSRange(location: offset(line: line, column: column), length: 0)) }
    }
}

extension NativeManuscriptTextView {
    func selectDocumentRange(_ selection: NSRange, reveal: Bool = true) {
        if let windowedDocument { windowedDocument.select(selection, reveal: reveal) }
        else { setSelectedRange(selection); if reveal { scrollCoordinator.revealSelection() } }
    }
    func replaceDocument(_ range: NSRange, with text: String, selectReplacement: Bool = false) {
        if let windowedDocument {
            windowedDocument.replace(range, with: text)
            if selectReplacement { windowedDocument.select(.init(location: range.location, length: text.utf16.count)) }
        } else { replace(range, with: text, selectReplacement: selectReplacement) }
    }
    func restoreDocumentAnchor(_ anchor: EditorScrollCoordinator.Anchor) {
        if let windowedDocument {
            windowedDocument.install(windowedDocument.document.range(around: anchor.offset), selection: documentSelection, anchor: anchor)
        } else { scrollCoordinator.restore(anchor) }
    }
    func documentViewportSnapshot() -> EditorViewportPosition? {
        windowedDocument?.snapshot() ?? scrollCoordinator.snapshot()
    }
    func reopenDocumentViewport(_ saved: EditorViewportPosition) {
        if let windowedDocument { windowedDocument.reopen(saved) }
        else { scrollCoordinator.reopen(saved) }
    }
}
