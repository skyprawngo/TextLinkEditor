import AppKit

/// Constructed without layout managers on a worker, then transferred once to the main thread.
/// Fix fallback fonts in bounded paragraph-aligned chunks before handing text to AppKit.
final class PreparedManuscript: @unchecked Sendable {
    let text: String
    let lineStarts: [Int]
    private var storage: NSTextStorage?
    let styleKey: String
    let typingAttributes: [NSAttributedString.Key: Any]

    private init(text: String, lineStarts: [Int], attributedText: NSAttributedString?, styleKey: String,
                 typingAttributes: [NSAttributedString.Key: Any]) {
        self.lineStarts = lineStarts
        self.text = text; self.storage = attributedText.map { NSTextStorage(attributedString: $0) }
        self.styleKey = styleKey; self.typingAttributes = typingAttributes
    }

    func takeStorage() -> NSTextStorage? {
        defer { storage = nil }
        return storage
    }

    static func build(text: String, styleKey: String, attributes: [NSAttributedString.Key: Any], buildsStorage: Bool = true) throws -> PreparedManuscript {
        let source = text as NSString
        let result = NSMutableAttributedString(string: "")
        var start = 0
        while buildsStorage && start < source.length {
            try Task.checkCancellation()
            let boundary = min(source.length, start + 16_384)
            let end = boundary == source.length ? boundary : NSMaxRange(source.paragraphRange(for: NSRange(location: boundary, length: 0)))
            autoreleasepool {
                let part = NSMutableAttributedString(string: source.substring(with: NSRange(location: start, length: end - start)), attributes: attributes)
                part.fixAttributes(in: NSRange(location: 0, length: part.length))
                result.append(part)
            }
            start = end
        }
        try Task.checkCancellation()
        var starts = [0]
        var offset = 0
        while offset < source.length {
            if starts.count % 1024 == 0 { try Task.checkCancellation() }
            let next = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < source.length { starts.append(next) }
            else if let scalar = UnicodeScalar(source.character(at: source.length - 1)), CharacterSet.newlines.contains(scalar) {
                starts.append(next)
            }
            offset = next
        }
        return PreparedManuscript(text: text, lineStarts: starts, attributedText: buildsStorage ? result.copy() as? NSAttributedString : nil,
                                  styleKey: styleKey, typingAttributes: attributes)
    }

    static func prepare(text: String, fontName: String, fontSize: CGFloat,
                        lineHeightMultiple: CGFloat, letterSpacing: CGFloat,
                        color: NSColor, buildsStorage: Bool = true) async throws -> PreparedManuscript {
        let styleKey = "\(fontName)|\(fontSize)|\(lineHeightMultiple)|\(letterSpacing)"
        let worker = Task.detached(priority: .userInitiated) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = lineHeightMultiple
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph.copy() as! NSParagraphStyle,
                .kern: letterSpacing, .foregroundColor: color]
            return try build(text: text, styleKey: styleKey, attributes: attributes, buildsStorage: buildsStorage)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
