import AppKit

/// Owns display-mode state and render invalidation, not document content or tool dispatch.
final class MarkdownPresentationController {
    private(set) var rendersMarkdown = false
    private var applyingMarkdown = false
    private var markdownRenderKey: String?
    private var renderedContentKey: String?
    private var parsedGeneration: Int?
    private var parsedDocument: MarkdownSyntaxDocument?

    func setMarkdownRendering(_ enabled: Bool, editor: NativeManuscriptTextView, style: EditorDisplayStyle?, generation: Int) {
        guard rendersMarkdown != enabled else { return }
        editor.commitComposition()
        rendersMarkdown = enabled
        refresh(editor: editor, style: style, generation: generation, reset: true)
    }

    func refresh(editor: NativeManuscriptTextView, style: EditorDisplayStyle?, generation: Int, reset: Bool = false, trackingSelection: Bool = false) {
        guard (rendersMarkdown || reset), !applyingMarkdown, !editor.hasMarkedText(),
              let storage = editor.textStorage, let style else { return }
        let contentKey = "\(generation)|\(style.key)|\(rendersMarkdown)"
        // SwiftUI configuration also calls refresh after selection publication.
        // Suppress selection-only reflow here so every entry point shares the rule;
        // actual text, appearance and mode changes must still render immediately.
        if !reset, renderedContentKey == contentKey,
           trackingSelection || editor.selectedRange().length > 0 { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(editor.selectedRange().location, storage.length), length: 0))
        let key = "\(generation)|\(paragraph.location)|\(style.key)|\(rendersMarkdown)"
        guard reset || markdownRenderKey != key else { return }
        markdownRenderKey = key
        renderedContentKey = contentKey
        applyingMarkdown = true
        defer { applyingMarkdown = false }
        let anchor = editor.scrollCoordinator.capture(for: .markdownRendering)
        storage.beginEditing()
        let whole = NSRange(location: 0, length: storage.length)
        storage.addAttributes(style.changedAttributes(from: nil), range: whole)
        for key in MarkdownSourceStyling.ownedKeys { storage.removeAttribute(key, range: whole) }
        if rendersMarkdown {
            if parsedGeneration != generation || parsedDocument == nil {
                parsedDocument = MarkdownSyntaxDocument(source: storage.string)
                parsedGeneration = generation
            }
            MarkdownSourceStyling.apply(to: storage, selection: editor.selectedRange(),
                font: NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize), document: parsedDocument)
        }
        storage.endEditing()
        editor.typingAttributes = style.changedAttributes(from: nil)
        if let anchor { editor.scrollCoordinator.restore(anchor) }
    }
    func invalidate() { markdownRenderKey = nil; renderedContentKey = nil; parsedGeneration = nil; parsedDocument = nil }
}
