import AppKit

/// Incremental UTF-16 line index. No view, selection, scrolling or rendering state.
struct ManuscriptLineIndex {
    private(set) var starts = [0]
    private(set) var needsRebuild = true
    private(set) var lastScannedUTF16Count = 0

    mutating func invalidate() { needsRebuild = true }
    mutating func adopt(_ preparedStarts: [Int]) {
        starts = preparedStarts
        needsRebuild = false
        lastScannedUTF16Count = 0
    }

    /// Rescan only the edited paragraphs, including neighbors for CRLF joins/splits.
    /// Storage notifications include Undo and IME edits as well as toolbar commands.
    mutating func update(_ storage: NSTextStorage) {
        guard !needsRebuild else { return }
        let range = storage.editedRange
        let delta = storage.changeInLength
        let oldEnd = NSMaxRange(range) - delta
        let first = line(at: max(0, range.location - 1))
        let suffix = min(starts.count, line(at: oldEnd) + 2)
        let start = starts[first]
        let end = suffix < starts.count ? starts[suffix] + delta : storage.length
        guard start <= end, end <= storage.length else { needsRebuild = true; return }
        let value = storage.attributedSubstring(from: NSRange(location: start, length: end - start)).string as NSString
        lastScannedUTF16Count = value.length
        var replacement = [start]
        var offset = 0
        while offset < value.length {
            let next = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < value.length { replacement.append(start + next) }
            else if suffix == starts.count, let scalar = UnicodeScalar(value.character(at: value.length - 1)),
                    CharacterSet.newlines.contains(scalar) { replacement.append(start + next) }
            offset = next
        }
        // No text scan or allocation of the untouched manuscript suffix.
        if delta != 0 {
            for index in suffix..<starts.count { starts[index] += delta }
        }
        starts.replaceSubrange(first..<suffix, with: replacement)
    }

    mutating func rebuild(_ text: String) {
        guard needsRebuild else { return }
        needsRebuild = false
        let value = text as NSString
        lastScannedUTF16Count = value.length
        var rebuiltStarts = [0]
        var offset = 0
        while offset < value.length {
            let next = NSMaxRange(value.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < value.length { rebuiltStarts.append(next) }
            else if value.length > 0, let scalar = UnicodeScalar(value.character(at: value.length - 1)), CharacterSet.newlines.contains(scalar) {
                rebuiltStarts.append(next)
            }
            offset = next
        }
        starts = rebuiltStarts
    }
    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
}
