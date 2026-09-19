import Foundation
import Markdown

/// Parser output contains source coordinates only. It has no dependency on AppKit,
/// selection, storage mutations, networking or editor tool dispatch.
struct MarkdownSyntaxDocument {
    enum Kind: Equatable {
        case heading(Int), strong, emphasis, strike, underline
        case code, codeBlock, quote, list, task(Bool), table, tableHeader
        case link(String), image(String), html, thematicBreak, hardBreak
    }
    struct Span {
        let kind: Kind
        let range: NSRange
        var markers: [NSRange] = []
    }
    let spans: [Span]

    private init(spans: [Span]) { self.spans = spans }

    /// Preserve block context across the window edges, then translate only visible spans.
    func window(_ range: NSRange) -> MarkdownSyntaxDocument {
        func local(_ value: NSRange) -> NSRange? {
            let intersection = NSIntersectionRange(value, range)
            guard intersection.length > 0 else { return nil }
            return NSRange(location: intersection.location - range.location, length: intersection.length)
        }
        return MarkdownSyntaxDocument(spans: spans.compactMap { span in
            guard let clipped = local(span.range) else { return nil }
            return Span(kind: span.kind, range: clipped, markers: span.markers.compactMap(local))
        })
    }

    init(source: String) {
        let map = MarkdownSourceCoordinates(source)
        let text = source as NSString
        var result: [Span] = []
        var underlineStart: NSRange?
        // An explicit stack avoids recursion in deeply nested, user-authored documents.
        var pending: [any Markup] = [Document(parsing: source, options: [.disableSmartOpts])]
        while let node = pending.popLast() {
            let children = Array(node.children)
            pending.append(contentsOf: children.reversed())
            guard let range = node.range.flatMap(map.range), range.length > 0 else { continue }
            let childRanges = children.compactMap { $0.range.flatMap(map.range) }
            let inner = childRanges.first.flatMap { first in childRanges.last.map {
                NSRange(location: first.location, length: NSMaxRange($0) - first.location)
            }}
            func delimiters() -> [NSRange] {
                guard let inner, inner.location >= range.location, NSMaxRange(inner) <= NSMaxRange(range) else { return [] }
                return [NSRange(location: range.location, length: inner.location - range.location),
                        NSRange(location: NSMaxRange(inner), length: NSMaxRange(range) - NSMaxRange(inner))].filter { $0.length > 0 }
            }
            var kind: Kind?
            var markers: [NSRange] = []
            switch node {
            case let heading as Heading: kind = .heading(heading.level); markers = delimiters()
            case is Strong: kind = .strong; markers = delimiters()
            case is Emphasis: kind = .emphasis; markers = delimiters()
            case is Strikethrough: kind = .strike; markers = delimiters()
            case is InlineCode:
                kind = .code
                let literal = text.substring(with: range)
                let count = literal.prefix(while: { $0 == "`" }).utf16.count
                if count > 0 && range.length >= count * 2 {
                    markers = [.init(location: range.location, length: count), .init(location: NSMaxRange(range) - count, length: count)]
                }
            case is CodeBlock: kind = .codeBlock
            case is BlockQuote: kind = .quote
            case is OrderedList, is UnorderedList: kind = .list
            case let item as ListItem:
                if let check = item.checkbox { kind = .task(check == .checked) }
            case is Table: kind = .table
            case is Table.Head: kind = .tableHeader
            case let link as Link: kind = .link(link.destination ?? ""); markers = delimiters()
            case let image as Image: kind = .image(image.source ?? "")
            case is HTMLBlock: kind = .html
            case let html as InlineHTML:
                kind = .html
                // Preserve the editor's existing <u> formatting tool without executing HTML.
                if html.rawHTML.lowercased() == "<u>" { underlineStart = range }
                if html.rawHTML.lowercased() == "</u>", let start = underlineStart {
                    result.append(.init(kind: .underline, range: .init(location: start.location, length: NSMaxRange(range) - start.location), markers: [start, range]))
                    underlineStart = nil
                }
            case is ThematicBreak: kind = .thematicBreak
            case is LineBreak: kind = .hardBreak
            default: break // Paragraphs, text and soft breaks keep the base editor style.
            }
            if let kind { result.append(.init(kind: kind, range: range, markers: markers)) }
        }
        spans = result
    }
}

/// cmark positions are 1-based UTF-8 byte columns; NSTextStorage uses UTF-16.
/// Build one mapping per parse, including CRLF, lone CR, emoji and combining marks.
private struct MarkdownSourceCoordinates {
    let lines: [Int]
    let lineOffsets: [Int]
    let bytes: [UInt8]
    init(_ source: String) {
        var lines = [0], lineOffsets = [0]
        var byte = 0, utf16 = 0
        var previousCR = false
        for scalar in source.unicodeScalars {
            byte += scalar.utf8.count
            utf16 += scalar.utf16.count
            if scalar == "\r" { lines.append(byte); lineOffsets.append(utf16) }
            else if scalar == "\n" {
                if previousCR { lines[lines.count - 1] = byte; lineOffsets[lineOffsets.count - 1] = utf16 }
                else { lines.append(byte); lineOffsets.append(utf16) }
            }
            previousCR = scalar == "\r"
        }
        self.lines = lines; self.lineOffsets = lineOffsets; self.bytes = Array(source.utf8)
    }
    func range(_ source: SourceRange) -> NSRange? {
        func offset(_ location: SourceLocation) -> Int? {
            guard lines.indices.contains(location.line - 1), location.column > 0 else { return nil }
            let line = location.line - 1
            let start = lines[line], end = start + location.column - 1
            guard end <= bytes.count, end >= start,
                  end == bytes.count || bytes[end] & 0xC0 != 0x80,
                  let prefix = String(bytes: bytes[start..<end], encoding: .utf8) else { return nil }
            return lineOffsets[line] + prefix.utf16.count
        }
        guard let start = offset(source.lowerBound), let end = offset(source.upperBound), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
