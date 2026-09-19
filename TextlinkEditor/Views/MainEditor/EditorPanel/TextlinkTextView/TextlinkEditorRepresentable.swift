//
//  TextlinkEditorRepresentable.swift
//  TextlinkEditor
//
//  TextlinkEditorView의 SwiftUI 래퍼
//

import SwiftUI

// MARK: - Lore Editor Representable

/// TextlinkEditorView를 SwiftUI에서 사용하기 위한 래퍼
struct TextlinkEditorRepresentable: NSViewRepresentable {
    @AppStorage(EditorRulerAppearance.widthKey, store: EditorRulerAppearance.store)
    private var rulerWidth = EditorRulerAppearance.defaultWidth

    @Binding var text: String
    @Binding var cursorLine: Int
    @Binding var cursorColumn: Int
    @Binding var selectedLineRange: ClosedRange<Int>?
    @Binding var externallyModifiedLines: Set<Int>

    let fontSize: CGFloat
    let fontName: String
    let lineHeightMultiple: CGFloat
    let letterSpacing: CGFloat
    let isEditable: Bool
    let initialCursorPosition: (line: Int, column: Int)?

    /// 탭 전환 시 현재 편집 중인 텍스트와 커서 위치를 부모에게 알리는 콜백
    /// (조합 중인 텍스트 확정 후의 최종 상태)
    var onContentWillChange: ((URL?, String, Int, Int) -> Void)?

    var documentID: UUID?
    var documentURL: URL?
    var editCommand: EditorCommand? = nil
    var contentRevision: UUID? = nil
    var isDocumentActive: ((UUID?, URL?, UUID?) -> Bool)? = nil
    var viewportStore: EditorViewportStore = .shared

    var openDocumentIDs: Set<UUID>? = nil
    var preparedContent: PreparedManuscript? = nil
    var isSourceVisible = true
    var rendersMarkdown = false
    var onToolPresentation: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NativeManuscriptHost {
        let coordinator = context.coordinator
        let native = NativeManuscriptTextView()
        coordinator.sourceVisible = isSourceVisible
        native.load(text, prepared: preparedContent)
        configure(native)
        let host = NativeManuscriptHost(textView: native)
        coordinator.host = host
        coordinator.observeScrolling()
        coordinator.documentID = documentID
        coordinator.documentURL = documentURL
        coordinator.contentRevision = contentRevision
        coordinator.presentedText = text
        if let documentID { coordinator.editors[documentID] = native }
        native.delegate = coordinator
        if let position = initialCursorPosition {
            native.setSelectedRange(NSRange(location: native.offset(line: position.line, column: position.column), length: 0))
        }
        coordinator.flushObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("editorWillPerformFileOperation"), object: nil, queue: .main
        ) { [weak coordinator] notification in
            guard let coordinator else { return }
            if let check = notification.userInfo?["checkComposition"] as? (Bool) -> Void {
                check(coordinator.host?.textView.hasMarkedText() ?? false)
                return
            }
            coordinator.flush()
            guard coordinator.parent.isDocumentActive?(coordinator.documentID, coordinator.documentURL, coordinator.contentRevision) ?? true,
                  let native = coordinator.host?.textView, native.isEditable else { return }
            if let capture = notification.userInfo?["captureSelection"] as? (String, NSRange) -> Void {
                capture(native.string, native.selectedRange())
            }
            if let apply = notification.userInfo?["applyRevision"] as? (String, NSRange) -> String?,
               let value = apply(native.string, native.selectedRange()) {
                native.applyExternalText(value, undoable: true)
                coordinator.flush()
            }
        }
        coordinator.restoreViewport()
        coordinator.focusAndPublish()
        return host
    }

    static func dismantleNSView(_ host: NativeManuscriptHost, coordinator: Coordinator) {
        coordinator.saveViewport()
        coordinator.stopObservingScrolling()
    }

    func updateNSView(_ host: NativeManuscriptHost, context: Context) {
        guard isDocumentActive?(documentID, documentURL, contentRevision) ?? true else { return }
        let coordinator = context.coordinator
        let becameVisible = isSourceVisible && !coordinator.sourceVisible
        coordinator.sourceVisible = isSourceVisible
        let changed = coordinator.documentID != documentID
        let finishedLoading = !coordinator.parent.isEditable && isEditable && coordinator.parent.isSourceVisible
        // Width/toolbar updates must not bridge and compare the entire NSTextStorage.
        // Retain the last binding value: unchanged Swift strings share their storage.
        let contentChanged = coordinator.contentRevision != contentRevision || coordinator.presentedText != text
        if let openDocumentIDs { coordinator.editors = coordinator.editors.filter { openDocumentIDs.contains($0.key) } }
        if coordinator.contentRevision != contentRevision { coordinator.pendingText = nil }
        if coordinator.pendingText == text { coordinator.pendingText = nil }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if changed {
            coordinator.flush()
            host.textView.delegate = nil
            let native = documentID.flatMap { coordinator.editors[$0] } ?? NativeManuscriptTextView()
            if native.string != text { native.load(text, prepared: preparedContent) }
            if let documentID { coordinator.editors[documentID] = native }
            if let position = initialCursorPosition {
                native.setSelectedRange(NSRange(location: native.offset(line: position.line, column: position.column), length: 0))
            }
            host.documentView = native
            host.tile()
            native.delegate = coordinator
            coordinator.pendingText = nil
        } else if contentChanged && coordinator.pendingText == nil && host.textView.string != text {
            if finishedLoading {
                host.textView.load(text, prepared: preparedContent)
                if let position = initialCursorPosition {
                    host.textView.setSelectedRange(NSRange(location: host.textView.offset(line: position.line, column: position.column), length: 0))
                }
            } else {
                host.textView.applyExternalText(text, prepared: preparedContent)
            }
        }
        coordinator.parent = self
        coordinator.documentID = documentID
        coordinator.documentURL = documentURL
        coordinator.contentRevision = contentRevision
        coordinator.presentedText = text
        configure(host.textView)
        host.setRulerWidth(rulerWidth)
        if changed || finishedLoading { coordinator.restoreViewport() }
        host.textView.modifiedLines = externallyModifiedLines
        host.verticalRulerView?.needsDisplay = true
        if let command = editCommand, coordinator.lastCommandID != command.id {
            coordinator.lastCommandID = command.id
            coordinator.scheduleCommand(command)
        }
        if changed || finishedLoading { coordinator.focusAndPublish() }
        else if becameVisible { coordinator.focusAndPublish(scrollToSelection: false) }
    }

    private func configure(_ view: NativeManuscriptTextView) {
        view.isEditable = isEditable
        view.isSelectable = true
        view.onToolPresentation = onToolPresentation
        view.applyDisplayStyle(EditorDisplayStyle(fontName: fontName, fontSize: fontSize,
                                                 lineHeightMultiple: lineHeightMultiple, letterSpacing: letterSpacing))
        // Resolve base appearance before the presentation module derives Markdown attributes.
        view.setMarkdownRendering(rendersMarkdown)
        view.refreshMarkdownRendering()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextlinkEditorRepresentable
        weak var host: NativeManuscriptHost?
        var documentID: UUID?
        var documentURL: URL?
        var contentRevision: UUID?
        var editors: [UUID: NativeManuscriptTextView] = [:]
        var pendingText: String?
        var presentedText: String?
        var flushObserver: NSObjectProtocol?
        var lastCommandID: UUID?
        var isUpdating = false
        private var scrollObserver: NSObjectProtocol?
        private var viewportSave: DispatchWorkItem?
        private var viewportReady = false
        private var textPublication = 0
        private var selectionPublication = 0
        deinit {
            viewportSave?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
        }
        init(parent: TextlinkEditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let native = notification.object as? NativeManuscriptTextView,
                  native === host?.textView else { return }
            native.rebuildLineIndex()
            publishText(native)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating else { return }
            host?.textView.refreshMarkdownRendering()
            publishSelection()
        }
        func flush() {
            saveViewport()
            guard let native = host?.textView else { return }
            native.commitComposition()
            native.rebuildLineIndex()
            guard native.isEditable else { return }
            publishText(native)
            if parent.isDocumentActive?(documentID, documentURL, contentRevision) ?? true { parent.text = native.string }
        }
        private func publishText(_ native: NativeManuscriptTextView) {
            textPublication &+= 1
            let publication = textPublication
            let value = native.string
            let position = native.position(at: native.selectedRange().location)
            pendingText = value
            parent.onContentWillChange?(documentURL, value, position.line, position.column)
            let id = documentID, url = documentURL, revision = contentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textPublication == publication, self.documentID == id, self.contentRevision == revision,
                      self.parent.isDocumentActive?(id, url, revision) ?? true else { return }
                self.parent.text = value
            }
            publishSelection()
        }
        private func publishSelection() {
            selectionPublication &+= 1
            let publication = selectionPublication
            guard let native = host?.textView else { return }
            if viewportReady { scheduleViewportSave() }
            let range = native.selectedRange()
            let position = native.position(at: range.location)
            let selected = range.length == 0 ? nil : (position.line + 1)...(native.line(at: NSMaxRange(range)) + 1)
            let id = documentID, url = documentURL, revision = contentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionPublication == publication, self.documentID == id, self.contentRevision == revision,
                      self.parent.isDocumentActive?(id, url, revision) ?? true else { return }
                self.parent.cursorLine = position.line + 1
                self.parent.cursorColumn = position.column
                self.parent.selectedLineRange = selected
            }
        }
        var sourceVisible = true

        func observeScrolling() {
            guard let clip = host?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                guard let self, !self.isUpdating, self.viewportReady else { return }
                self.scheduleViewportSave()
            }
        }

        private func scheduleViewportSave() {
            viewportSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveViewport() }
            viewportSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func stopObservingScrolling() {
            viewportSave?.cancel()
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
        }

        func saveViewport() {
            viewportSave?.cancel()
            guard viewportReady, parent.isEditable, let url = documentURL,
                  let snapshot = host?.textView.scrollCoordinator.snapshot() else { return }
            parent.viewportStore.save(snapshot, for: url)
        }

        @discardableResult
        func restoreViewport() -> Bool {
            viewportReady = false
            viewportSave?.cancel()
            guard parent.isEditable, let url = documentURL, let native = host?.textView,
                  let saved = parent.viewportStore.position(for: url) else { return false }
            native.scrollCoordinator.reopen(saved)
            return true
        }

        // Tool callbacks may write SwiftUI state. Never invoke them from updateNSView.
        func scheduleCommand(_ command: EditorCommand) {
            let id = documentID, url = documentURL, revision = contentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.documentID == id, self.documentURL == url,
                      self.contentRevision == revision,
                      self.parent.isDocumentActive?(id, url, revision) ?? true,
                      let native = self.host?.textView else { return }
                native.execute(command)
            }
        }

        func focusAndPublish(scrollToSelection: Bool = true) {
            let id = documentID, revision = contentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isSourceVisible, self.documentID == id, self.contentRevision == revision,
                      self.parent.isDocumentActive?(id, self.documentURL, revision) ?? true,
                      let native = self.host?.textView else { return }
                if EditorFocusCoordinator.permitsAutomaticFocus(in: native.window) {
                    native.window?.makeFirstResponder(native)
                }
                if scrollToSelection && !self.restoreViewport() { native.scrollCoordinator.revealSelection() }
                self.viewportReady = self.parent.isEditable
                self.publishSelection()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TextlinkEditorRepresentable(
        text: .constant("# Hello, World!\n\nThis is a test.\nLine 4\nLine 5\n\n한글 테스트입니다.\n긴 텍스트 테스트입니다."),
        cursorLine: .constant(1),
        cursorColumn: .constant(0),
        selectedLineRange: .constant(nil),
        externallyModifiedLines: .constant([3, 4]),
        fontSize: 14,
        fontName: "SF Pro",
        lineHeightMultiple: 1.5,
        letterSpacing: 0,
        isEditable: true,
        initialCursorPosition: nil,
        onContentWillChange: { _, _, _, _ in },
        documentID: nil,
        documentURL: nil
    )
    .frame(width: 600, height: 400)
}
