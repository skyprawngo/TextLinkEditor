import Foundation

/// Read-only presentation model for Git's unified patch. Unknown/combined output
/// remains visible as metadata rather than being mistaken for ordinary diff rows.
struct CommitDiffDocument {
    struct Line: Identifiable {
        enum Kind { case added, removed, context, note }
        let id: Int
        let text: String
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
    }
    struct Hunk: Identifiable {
        let id: Int
        let header: String
        var lines: [Line] = []
        var added: Int { lines.filter { $0.kind == .added }.count }
        var removed: Int { lines.filter { $0.kind == .removed }.count }
    }
    struct File: Identifiable {
        let id: Int
        var title: String
        var metadata: [String] = []
        var hunks: [Hunk] = []
        var added: Int { hunks.reduce(0) { $0 + $1.added } }
        var removed: Int { hunks.reduce(0) { $0 + $1.removed } }
    }
    let summary: String
    let files: [File]
    init(patch: String) {
        let pattern = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var summary: [String] = [], files: [File] = []
        var old = 0, new = 0
        for (index, line) in patch.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                files.append(.init(id: index, title: String(line.dropFirst(line.hasPrefix("diff --git ") ? 11 : line.hasPrefix("diff --cc ") ? 10 : 16))))
                continue
            }
            guard let f = files.indices.last else { summary.append(line); continue }
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let value = line as NSString
                old = Int(value.substring(with: match.range(at: 1))) ?? 0
                new = Int(value.substring(with: match.range(at: 2))) ?? 0
                files[f].hunks.append(.init(id: index, header: line))
            } else if let h = files[f].hunks.indices.last {
                let kind: Line.Kind
                let oldNumber: Int?, newNumber: Int?
                switch line.first {
                case "+": kind = .added; oldNumber = nil; newNumber = new; new += 1
                case "-": kind = .removed; oldNumber = old; newNumber = nil; old += 1
                case " ": kind = .context; oldNumber = old; newNumber = new; old += 1; new += 1
                default: kind = .note; oldNumber = nil; newNumber = nil
                }
                if !line.isEmpty { files[f].hunks[h].lines.append(.init(id: index, text: line, kind: kind, oldNumber: oldNumber, newNumber: newNumber)) }
            } else {
                files[f].metadata.append(line)
                if line.hasPrefix("--- a/") { files[f].title = String(line.dropFirst(6)) }
                if line.hasPrefix("+++ b/") { files[f].title = String(line.dropFirst(6)) }
                if line.hasPrefix("rename to ") { files[f].title = String(line.dropFirst(10)) }
            }
        }
        self.summary = summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.files = files
    }
}
