import AppKit

/// Source-preserving renderer. Parsing, networking and document writes belong elsewhere.
enum MarkdownSourceStyling {
    static let semanticKey = NSAttributedString.Key("TextlinkMarkdownKind")
    static let ownedKeys: [NSAttributedString.Key] = [.strikethroughStyle, .underlineStyle, .backgroundColor, .link, .toolTip, .obliqueness, semanticKey]

    static func apply(to storage: NSTextStorage, selection: NSRange, font: NSFont, document: MarkdownSyntaxDocument? = nil) {
        let document = document ?? MarkdownSyntaxDocument(source: storage.string)
        let source = storage.string as NSString
        let active = source.paragraphRange(for: .init(location: min(selection.location, source.length), length: 0))
        var markers: [(NSRange, NSRange)] = []
        func attribute(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange) {
            storage.addAttribute(key, value: value, range: range)
        }
        func fonts(_ range: NSRange, _ transform: (NSFont) -> NSFont) {
            var runs: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                runs.append((subrange, transform(value as? NSFont ?? font)))
            }
            for (range, value) in runs { attribute(.font, value, range) }
        }
        for span in document.spans {
            let range = span.range
            guard range.location >= 0, NSMaxRange(range) <= storage.length else { continue }
            attribute(semanticKey, String(describing: span.kind), range)
            switch span.kind {
            case .heading(let level):
                let scale: [CGFloat] = [1.8, 1.5, 1.3, 1.15, 1.05, 1]
                let sized = NSFontManager.shared.convert(font, toSize: font.pointSize * scale[min(5, max(0, level - 1))])
                attribute(.font, NSFontManager.shared.convert(sized, toHaveTrait: .boldFontMask), range)
            case .strong, .tableHeader:
                fonts(range) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            case .emphasis:
                fonts(range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
                // CJK fallback families often have no italic face. Keep their glyphs
                // and weight while providing the emphasis visually.
                var fallback: [NSRange] = []
                storage.enumerateAttribute(.font, in: range) { value, run, _ in
                    if let value = value as? NSFont, !NSFontManager.shared.traits(of: value).contains(.italicFontMask) { fallback.append(run) }
                }
                for run in fallback { attribute(.obliqueness, 0.2, run) }
            case .strike: attribute(.strikethroughStyle, NSUnderlineStyle.single.rawValue, range)
            case .underline: attribute(.underlineStyle, NSUnderlineStyle.single.rawValue, range)
            case .code, .codeBlock:
                attribute(.font, NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range)
                attribute(.backgroundColor, NSColor.quaternaryLabelColor, range)
            case .quote:
                attribute(.foregroundColor, NSColor.secondaryLabelColor, range)
            case .list: break // Retain source numbering and markers.
            case .task(let checked):
                attribute(.toolTip, checked ? "☑" : "☐", range)
                if checked { attribute(.foregroundColor, NSColor.secondaryLabelColor, range) }
            case .table:
                attribute(.font, NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range)
                attribute(.backgroundColor, NSColor.quaternaryLabelColor, range)
            case .link(let destination):
                attribute(.foregroundColor, NSColor.linkColor, range)
                attribute(.underlineStyle, NSUnderlineStyle.single.rawValue, range)
                attribute(.toolTip, destination, range)
                if let url = URL(string: destination), let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
                    attribute(.link, url, range)
                }
            case .image(let destination):
                attribute(.foregroundColor, NSColor.secondaryLabelColor, range)
                attribute(.toolTip, destination, range)
            case .html: attribute(.foregroundColor, NSColor.secondaryLabelColor, range)
            case .thematicBreak: attribute(.foregroundColor, NSColor.separatorColor, range)
            case .hardBreak: break
            }
            markers.append(contentsOf: span.markers.map { ($0, range) })
        }
        // Apply delimiters last so nested formatting cannot reveal outer markers.
        for (range, owner) in markers where NSMaxRange(range) <= storage.length {
            if NSIntersectionRange(active, owner).length > 0 {
                attribute(.foregroundColor, NSColor.secondaryLabelColor, range)
            } else {
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.01), .kern: 0], range: range)
            }
        }
    }
}
