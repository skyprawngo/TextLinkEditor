import Foundation

enum ManuscriptWindowPolicy {
    static let linesPerChunk = 256
    static let residentChunks = 3
    static let prefetchLines = 128
}

/// Full source belongs to the document; NSTextStorage contains only a paragraph window.
/// All persistent positions and undo edits use document UTF-16 offsets.
final class ManuscriptWindowDocument {
    private let source: NSMutableString
    private(set) var starts: [Int]
    private var syntax: MarkdownSyntaxDocument?
    func markdown(in range: NSRange) -> MarkdownSyntaxDocument {
        if syntax == nil { syntax = MarkdownSyntaxDocument(source: text) }
        return syntax!.window(range)
    }
    var text: String { source as String }
    var length: Int { source.length }
    init(_ text: String, starts: [Int]? = nil) {
        source = NSMutableString(string: text)
        self.starts = starts ?? Self.scan(text as NSString)
    }
    static func scan(_ value: NSString) -> [Int] {
        var result = [0], offset = 0
        while offset < value.length {
            let end = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            guard end > offset else { break }
            if end < value.length || (end > 0 && CharacterSet.newlines.contains(UnicodeScalar(value.character(at: end - 1)) ?? " ")) { result.append(end) }
            offset = end
        }
        return result
    }
    func line(at offset: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= offset { lo = mid + 1 } else { hi = mid } }
        return max(0, lo - 1)
    }
    func substring(_ range: NSRange) -> String { source.substring(with: range) }
    func lineText(_ row: Int) -> String {
        let row = min(max(0, row), starts.count - 1)
        let end = row + 1 < starts.count ? starts[row + 1] : length
        return substring(NSRange(location: starts[row], length: end - starts[row])).trimmingCharacters(in: .newlines)
    }
    func position(_ offset: Int) -> (line: Int, column: Int) {
        let offset = min(length, max(0, offset)), row = line(at: offset)
        return (row, substring(NSRange(location: starts[row], length: offset - starts[row])).count)
    }
    func offset(line: Int, column: Int) -> Int {
        let row = min(max(0, line), starts.count - 1)
        return starts[row] + lineText(row).prefix(max(0, column)).utf16.count
    }
    func range(around offset: Int) -> NSRange {
        let row = line(at: offset)
        let first = max(0, (row / ManuscriptWindowPolicy.linesPerChunk - 1) * ManuscriptWindowPolicy.linesPerChunk)
        let last = min(starts.count, first + ManuscriptWindowPolicy.linesPerChunk * ManuscriptWindowPolicy.residentChunks)
        return NSRange(location: starts[first], length: (last < starts.count ? starts[last] : length) - starts[first])
    }
    @discardableResult func replace(_ range: NSRange, with replacement: String) -> String {
        syntax = nil
        let old = substring(range)
        let first = line(at: max(0, range.location - 1))
        let suffix = min(starts.count, line(at: NSMaxRange(range)) + 2)
        let start = starts[first]
        let delta = replacement.utf16.count - range.length
        let end = suffix < starts.count ? starts[suffix] + delta : length + delta
        source.replaceCharacters(in: range, with: replacement)
        var changed = Self.scan(source.substring(with: NSRange(location: start, length: end - start)) as NSString).map { start + $0 }
        if suffix < starts.count, changed.last == end { changed.removeLast() }
        for index in suffix..<starts.count { starts[index] += delta }
        starts.replaceSubrange(first..<suffix, with: changed)
        return old
    }
}

