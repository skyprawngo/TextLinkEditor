import AppKit
import SwiftUI

private struct AIPanelResizeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aiPanelIsResizing: Bool {
        get { self[AIPanelResizeKey.self] }
        set { self[AIPanelResizeKey.self] = newValue }
    }
}

/// TextKit owns reflow and selection; SwiftUI owns conversation controls.
struct AITranscriptScrollView: NSViewRepresentable {
    @Environment(\.aiPanelIsResizing) private var isResizing
    struct Entry: Equatable {
        let id: UUID
        let text: String
        let isUser: Bool
        let tag: String?
        let revisionTitle: String?
    }
    let entries: [Entry]
    let conversationID: UUID?
    let fontName: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let letterSpacing: CGFloat
    let processingText: String?
    let onRevision: (UUID) -> Void
    let onComment: (String) -> Void
    let commentTitle: String
    let copyTitle: String
    var projectURL: URL? = nil
    var onOpenFile: (URL) -> Void = { _ in }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptScrollView, context: Context) -> CGSize? {
        // The viewport fills its allocated space; the document's measured height
        // must never feed back into SwiftUI's proposal for that same viewport.
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 300)
    }

    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = scroll.transcript
        return scroll
    }

    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        scroll.setInteractiveResize(isResizing)
        scroll.transcript.onRevision = onRevision
        scroll.transcript.projectURL = projectURL
        scroll.transcript.onOpenFile = onOpenFile
        scroll.transcript.onComment = onComment
        scroll.transcript.commentTitle = commentTitle
        scroll.transcript.copyTitle = copyTitle
        let key = RenderKey(entries: entries, fontName: fontName, fontSize: fontSize,
                            lineSpacing: lineSpacing, letterSpacing: letterSpacing, processingText: processingText,
                            projectURL: projectURL)
        let switched = scroll.conversationID != conversationID
        guard switched || scroll.renderKey != key else { return }
        let firstRender = scroll.renderKey == nil
        scroll.renderKey = key
        scroll.conversationID = conversationID
        let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let body = NSMutableAttributedString()
        var records: [TranscriptTextView.Record] = []
        for entry in entries {
            let start = body.length
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.paragraphSpacing = 0
            paragraph.headIndent = 0
            paragraph.firstLineHeadIndent = paragraph.headIndent
            paragraph.tailIndent = 0
            if entry.isUser { paragraph.alignment = .left }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                .kern: letterSpacing, .paragraphStyle: paragraph]
            if let tag = entry.tag {
                body.append(NSAttributedString(string: tag + "\n", attributes: attributes.merging([
                    .font: NSFont.systemFont(ofSize: max(10, fontSize - 2)), .foregroundColor: NSColor.secondaryLabelColor
                ]) { _, new in new }))
            }
            body.append(entry.isUser ? NSAttributedString(string: entry.text, attributes: attributes)
                : TranscriptFileLinks.render(entry.text, attributes: attributes, project: projectURL))
            if let title = entry.revisionTitle {
                body.append(NSAttributedString(string: "\n" + title, attributes: attributes.merging([
                    .link: URL(string: "textlink-revision://" + entry.id.uuidString)!, .foregroundColor: NSColor.linkColor
                ]) { _, new in new }))
            }
            // A dedicated separator gives each message a stable source range and spacing.
            body.append(NSAttributedString(string: "\n", attributes: attributes))
            records.append(.init(range: NSRange(location: start, length: body.length - start), entry: entry))
            let separator = NSMutableParagraphStyle()
            separator.minimumLineHeight = 20
            separator.maximumLineHeight = 20
            body.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: separator]))
        }
        let processingOffset = processingText == nil ? nil : body.length
        if let processingText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 20
            paragraph.headIndent = 20
            body.append(NSAttributedString(string: processingText, attributes: [.font: font,
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
        }
        DispatchQueue.main.async { [weak scroll] in
            guard let scroll, scroll.renderKey == key, scroll.conversationID == conversationID else { return }
            let follow = switched || firstRender || scroll.isAtBottom
            let anchor = scroll.transcript.captureBottomAnchor()
            scroll.transcript.replace(body, records: records, processingOffset: processingOffset)
            if follow { scroll.followEnd() }
            else if let anchor { scroll.restoreAfterLayout(anchor) }
        }
    }

    struct RenderKey: Equatable {
        let entries: [Entry]
        let fontName: String
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        let letterSpacing: CGFloat
        let processingText: String?
        let projectURL: URL?
    }
}

final class TranscriptScrollView: NSScrollView {
    let transcript = TranscriptTextView()
    var renderKey: AITranscriptScrollView.RenderKey?
    var conversationID: UUID?
    var isAtBottom: Bool { transcript.bounds.height - contentView.bounds.maxY < 64 }
    private var pendingAnchor: TranscriptTextView.Anchor?
    private var pendingEnd = false
    private var layoutScheduled = false
    private var restoring = false
    private var interactiveResize = false
    private var interactiveAnchor: TranscriptTextView.Anchor?

    func setInteractiveResize(_ value: Bool) {
        guard value != interactiveResize else { return }
        interactiveResize = value
        if !value { interactiveAnchor = nil }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if !restoring, newSize != frame.size, !pendingEnd, pendingAnchor == nil {
            pendingAnchor = interactiveAnchor ?? transcript.captureBottomAnchor()
            if interactiveResize { interactiveAnchor = pendingAnchor }
        }
        super.setFrameSize(newSize)
        if pendingAnchor != nil { scheduleLayout() }
    }
    func followEnd() { pendingEnd = true; pendingAnchor = nil; scheduleLayout() }
    func restoreAfterLayout(_ anchor: TranscriptTextView.Anchor) {
        if !pendingEnd, pendingAnchor == nil { pendingAnchor = anchor }
        scheduleLayout()
    }
    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        // Coalesce all geometry changes in this run-loop turn and avoid forcing
        // AppKit layout recursively inside SwiftUI's updateNSView/layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoring = true
            self.layoutSubtreeIfNeeded()
            let anchor = self.pendingAnchor
            self.pendingAnchor = nil
            if self.pendingEnd {
                self.pendingEnd = false
                self.transcript.scrollRangeToVisible(NSRange(location: self.transcript.textStorage?.length ?? 0, length: 0))
                self.transcript.layoutManager?.ensureLayout(for: self.transcript.textContainer!)
                self.contentView.scroll(to: NSPoint(x: 0, y: max(0, self.transcript.bounds.height - self.contentSize.height)))
                self.reflectScrolledClipView(self.contentView)
            } else if let anchor { self.transcript.restoreBottomAnchor(anchor) }
            self.restoring = false
            self.layoutScheduled = false
        }
    }
}

/// Narrow the whole message column while keeping its paragraphs left aligned.
private final class TranscriptTextContainer: NSTextContainer {
    var userMessages: [(range: NSRange, naturalWidth: CGFloat)] = []
    override var isSimpleRectangularTextContainer: Bool { false }

    func bubbleBounds(at offset: Int) -> (x: CGFloat, width: CGFloat)? {
        guard let message = userMessages.first(where: { NSLocationInRange(offset, $0.range) }) else { return nil }
        let width = min(max(24, ceil(message.naturalWidth) + 24), size.width * 0.9)
        return (size.width - width, width)
    }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        if let bubble = bubbleBounds(at: characterIndex) {
            rect.origin.x = bubble.x + 12
            rect.size.width = max(1, bubble.width - 24)
        }
        return rect
    }
}

/// Anchors the last visible text line by UTF-16 offset, not total content height.
final class TranscriptTextView: NSTextView, NSTextViewDelegate {
    struct Record { let range: NSRange; let entry: AITranscriptScrollView.Entry }
    struct Anchor { let offset: Int; let bottomDistance: CGFloat }
    var onRevision: (UUID) -> Void = { _ in }
    var projectURL: URL?
    var onOpenFile: (URL) -> Void = { _ in }
    var onComment: (String) -> Void = { _ in }
    var commentTitle = ""
    var copyTitle = ""
    private var records: [Record] = []
    private var processingOffset: Int?
    private let progress = NSProgressIndicator()
    // Compensate for the composer's 24pt overlap and leave another 8pt of breathing room.
    private static let bottomClearance: CGFloat = 32

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        // NSTextView's inset is symmetric. Keep the top at 14pt and assign the
        // additional vertical inset entirely to the scrollable document's bottom.
        origin.y -= Self.bottomClearance / 2
        return origin
    }

    init() {
        let content = NSTextStorage()
        let manager = NSLayoutManager()
        content.addLayoutManager(manager)
        let container = TranscriptTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 1), textContainer: container)
        delegate = self
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 14, height: 14 + Self.bottomClearance / 2)
        container.lineFragmentPadding = 0
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func replace(_ text: NSAttributedString, records: [Record], processingOffset: Int?) {
        let selection = selectedRange()
        self.records = records
        self.processingOffset = processingOffset
        if processingOffset != nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if let container = textContainer as? TranscriptTextContainer {
            container.userMessages = records.filter { $0.entry.isUser }.map { record in
                let measured = NSMutableAttributedString(attributedString: text.attributedSubstring(from: record.range))
                measured.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: measured.length))
                return (record.range, measured.size().width)
            }
        }
        textStorage?.setAttributedString(text)
        if NSMaxRange(selection) <= text.length { setSelectedRange(selection) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let processingOffset, let rect = lineRect(at: processingOffset) {
            progress.frame = NSRect(x: textContainerOrigin.x, y: rect.midY + textContainerOrigin.y - 7, width: 14, height: 14)
        }
    }

    func captureBottomAnchor() -> Anchor? {
        guard let scroll = enclosingScrollView, let storage = textStorage, storage.length > 0 else { return nil }
        let bottom = scroll.contentView.bounds.maxY
        let point = NSPoint(x: textContainerOrigin.x + 1, y: bottom - 1)
        let offset = min(characterIndexForInsertion(at: point), storage.length)
        guard let rect = lineRect(at: offset) else { return nil }
        return Anchor(offset: offset, bottomDistance: bottom - rect.maxY - textContainerOrigin.y)
    }

    func restoreBottomAnchor(_ anchor: Anchor) {
        guard let scroll = enclosingScrollView, let rect = lineRect(at: anchor.offset) else { return }
        let y = rect.maxY + textContainerOrigin.y + anchor.bottomDistance - scroll.contentSize.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func lineRect(at offset: Int) -> NSRect? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: min(max(0, offset), storage.length - 1))
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let manager = layoutManager, let container = textContainer else { return }
        let visible = manager.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: container)
        let visibleCharacters = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        for record in records where record.entry.isUser && NSIntersectionRange(record.range, visibleCharacters).length > 0 {
            let glyphs = manager.glyphRange(forCharacterRange: record.range, actualCharacterRange: nil)
            var frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard let bubble = (container as? TranscriptTextContainer)?.bubbleBounds(at: record.range.location) else { continue }
            frame.origin.x = textContainerOrigin.x + bubble.x
            frame.size.width = bubble.width
            NSBezierPath(roundedRect: frame.insetBy(dx: 0, dy: -6), xRadius: 12, yRadius: 12).fill()
            if let tag = record.entry.tag, !tag.isEmpty {
                let tagRange = NSRange(location: record.range.location, length: tag.utf16.count)
                let tagGlyphs = manager.glyphRange(forCharacterRange: tagRange, actualCharacterRange: nil)
                let tagRect = manager.boundingRect(forGlyphRange: tagGlyphs, in: container)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -4, dy: -2)
                NSBezierPath(roundedRect: tagRect, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.isFileURL {
            if let file = TranscriptFileLinks.existingFile(url, project: projectURL) { onOpenFile(file) }
            return true
        }
        guard let url = link as? URL, url.scheme == "textlink-revision", let host = url.host, let id = UUID(uuidString: host) else { return false }
        onRevision(id)
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let record = records.first(where: { NSLocationInRange(offset, $0.range) }) {
            let copy = NSMenuItem(title: copyTitle, action: #selector(copyMessage(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = record.entry.text
            menu.addItem(copy)
            let item = NSMenuItem(title: commentTitle, action: #selector(comment(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.entry.text
            menu.addItem(item)
        }
        return menu
    }
    @objc private func comment(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { onComment(text) }
    }
    @objc private func copyMessage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Resolve transcript references against the owning project, never the process cwd.
enum TranscriptFileLinks {
    private static let links = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let code = try! NSRegularExpression(pattern: #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`\n]*`"#)

    static func existingFile(_ url: URL, project: URL?) -> URL? {
        guard let project, url.isFileURL else { return nil }
        let root = project.resolvingSymlinksInPath().standardizedFileURL
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard file.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &directory),
              !directory.boolValue else { return nil }
        return file
    }

    static func render(_ text: String, attributes: [NSAttributedString.Key: Any], project: URL?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        guard let project else { return result }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let codeRanges = code.matches(in: text, range: range).map(\.range)
        for match in links.matches(in: text, range: range).reversed() {
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let destination = source.substring(with: match.range(at: 2))
            guard let components = URLComponents(string: destination), components.scheme == nil,
                  components.host == nil, !components.path.hasPrefix("/"), !components.path.isEmpty,
                  let file = existingFile(project.appendingPathComponent(components.path), project: project) else { continue }
            let label = source.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: label,
                attributes: attributes.merging([.link: file, .foregroundColor: NSColor.linkColor]) { _, new in new }))
        }
        return result
    }
}
