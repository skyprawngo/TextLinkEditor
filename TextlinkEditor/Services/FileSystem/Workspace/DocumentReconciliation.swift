import Foundation

/// Pure three-version rule, shared by disk refresh and write preflight.
/// Filesystem events and modification dates are hints; complete content is the equality authority.
enum DocumentReconciliation {
    enum Decision: Equatable { case unchanged, adoptDisk, conflict }
    static func decide(base: String, draft: String, disk: String) -> Decision {
        if disk == base { return .unchanged }
        if draft == base || draft == disk { return .adoptDisk }
        return .conflict
    }
}

struct DocumentReadIdentity {
    let requestID: UUID
    let documentID: UUID
    let base: String?
    func matches(requestID: UUID?, documentID: UUID?, base: String?) -> Bool {
        self.requestID == requestID && self.documentID == documentID && self.base == base
    }
}

/// Text-derived three-way patches. Coordinates are internal UTF-16 offsets, never
/// model-supplied line numbers. Every replacement is checked against its old text.
enum ManuscriptTextMerge {
    enum Failure: Error { case overlap, tooComplex }
    struct Patch: Equatable {
        let range: NSRange
        let before: String
        let after: String
        var end: Int { NSMaxRange(range) }
    }

    static func merge(base: String, current: String, proposed: String,
                      allowingProposedDeletions: Bool = false) throws -> String {
        if current == base || current == proposed { return proposed }
        if proposed == base { return current }
        let local = try patches(from: base, to: current)
        let incoming = try patches(from: base, to: proposed)
        var rebased: [Patch] = []
        for edit in incoming {
            var shift = 0, coveredDelta = 0, alreadyApplied = false
            for other in local {
                if edit == other { alreadyApplied = true; break }
                let intersects: Bool
                if edit.range.length == 0 && other.range.length == 0 {
                    intersects = edit.range.location == other.range.location
                } else if edit.range.length == 0 {
                    intersects = edit.range.location > other.range.location && edit.range.location < other.end
                } else if other.range.length == 0 {
                    intersects = other.range.location > edit.range.location && other.range.location < edit.end
                } else {
                    intersects = max(edit.range.location, other.range.location) < min(edit.end, other.end)
                }
                let delta = (other.after as NSString).length - other.range.length
                if intersects {
                    guard allowingProposedDeletions, edit.after.isEmpty, edit.range.length > 0,
                          other.range.location >= edit.range.location, other.end <= edit.end else { throw Failure.overlap }
                    coveredDelta += delta
                } else if other.end <= edit.range.location {
                    shift += delta
                }
            }
            if alreadyApplied { continue }
            let range = NSRange(location: edit.range.location + shift, length: edit.range.length + coveredDelta)
            let text = current as NSString
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else { throw Failure.overlap }
            let expected = text.substring(with: range)
            // Deletion explicitly consumes enclosed concurrent edits. Every other
            // hunk must still contain precisely the captured old text.
            guard (allowingProposedDeletions && edit.after.isEmpty) || expected == edit.before else { throw Failure.overlap }
            rebased.append(Patch(range: range, before: expected, after: edit.after))
        }
        let result = NSMutableString(string: current)
        for patch in rebased.reversed() {
            guard result.substring(with: patch.range) == patch.before else { throw Failure.overlap }
            result.replaceCharacters(in: patch.range, with: patch.after)
        }
        return result as String
    }

    static func patches(from old: String, to new: String) throws -> [Patch] {
        if old == new { return [] }
        // Keep line terminators, including CRLF, exactly as authored.
        func lines(_ text: String) -> [String] {
            var values = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for index in values.indices.dropLast() { values[index] += "\n" }
            return values
        }
        let coarse = try diff(lines(old), lines(new))
        var result: [Patch] = []
        for patch in coarse {
            // Refine each changed paragraph so two edits on the same line can merge.
            let fine = try diff(patch.before.map(String.init), patch.after.map(String.init))
            result += fine.map { Patch(range: NSRange(location: patch.range.location + $0.range.location,
                                                       length: $0.range.length), before: $0.before, after: $0.after) }
        }
        return result
    }

    private static func diff(_ old: [String], _ new: [String]) throws -> [Patch] {
        var prefix = 0, aEnd = old.count, bEnd = new.count
        while prefix < min(aEnd, bEnd), old[prefix] == new[prefix] { prefix += 1 }
        while aEnd > prefix, bEnd > prefix, old[aEnd - 1] == new[bEnd - 1] { aEnd -= 1; bEnd -= 1 }
        let a = Array(old[prefix..<aEnd]), b = Array(new[prefix..<bEnd])
        let offset = old[..<prefix].reduce(0) { $0 + ($1 as NSString).length }
        if a.isEmpty || b.isEmpty {
            let before = a.joined()
            return before == b.joined() ? [] : [Patch(range: NSRange(location: offset, length: (before as NSString).length), before: before, after: b.joined())]
        }
        // Bound worst-case CollectionDifference work; never fall back to overwriting.
        if a.count > 8_000 || b.count > 8_000 || a.count * b.count > 4_000_000 {
            // Split book-sized sparse edits at an exact unique text anchor before
            // running the bounded diff on each side. Repeated/ambiguous text fails closed.
            func uniqueIndices(_ values: [String]) -> [String: Int] {
                var result: [String: Int] = [:]
                for (index, value) in values.enumerated() {
                    if result[value] == nil { result[value] = index } else { result[value] = -1 }
                }
                return result
            }
            let left = uniqueIndices(a), right = uniqueIndices(b)
            let anchors = left.compactMap { text, index -> (Int, Int)? in
                guard index >= 0, let other = right[text], other >= 0 else { return nil }
                return (index, other)
            }
            guard let anchor = anchors.min(by: {
                abs($0.0 - a.count / 2) + abs($0.1 - b.count / 2) < abs($1.0 - a.count / 2) + abs($1.1 - b.count / 2)
            }) else { throw Failure.tooComplex }
            let first = try diff(Array(a[..<anchor.0]), Array(b[..<anchor.1]))
            let second = try diff(Array(a[(anchor.0 + 1)...]), Array(b[(anchor.1 + 1)...]))
            let tailOffset = a[...anchor.0].reduce(0) { $0 + ($1 as NSString).length }
            return first.map { Patch(range: NSRange(location: offset + $0.range.location, length: $0.range.length), before: $0.before, after: $0.after) }
                + second.map { Patch(range: NSRange(location: offset + tailOffset + $0.range.location, length: $0.range.length), before: $0.before, after: $0.after) }
        }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var i = 0, j = 0, position = offset, result: [Patch] = []
        while i < a.count || j < b.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = position
                var before = "", after = ""
                while i < a.count, removed.contains(i) { before += a[i]; position += (a[i] as NSString).length; i += 1 }
                while j < b.count, inserted.contains(j) { after += b[j]; j += 1 }
                result.append(Patch(range: NSRange(location: start, length: position - start), before: before, after: after))
            } else {
                position += (a[i] as NSString).length; i += 1; j += 1
            }
        }
        return result
    }
}
