#!/usr/bin/env python3
"""Run production proposal diff/apply code without any account or manuscript writes."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'TextlinkEditor/Services/AI/Revision/ManuscriptRevision.swift').read_text().split('@MainActor')[0]
harness = r'''
enum L10n { static func get(_ value: String) -> String { value } }
func check(_ condition: Bool, _ label: String) { if !condition { fatalError(label) } }
func revision(_ text: String) -> ManuscriptRevision {
    ManuscriptRevision(id: UUID(), relativePath: "draft.md", original: text, selectionLocation: 0, selectionLength: (text as NSString).length)
}
for (old, new) in [("a\nb\nc", "a\nx\nc"), ("a\nb\nc\nd", "a\nx\nc\ny"), ("a", "\na"), ("a\n", "a\n\n"), ("a\nb", "b"), ("", "😀\n한글"), ("a", ""), ("a\n\na", "a\na"), ("a\nb", "a\n\nb")] {
    let r = revision(old), changes = r.changes(proposal: new)
    check(try r.applying(proposal: new, selected: Set(changes.map(\.id)), to: old) == new, "full patch: \(old) → \(new)")
    check(try r.applying(proposal: new, selected: [], to: old) == old, "rejection")
}
let r = revision("a\nb\nc\nd")
check(try r.applying(proposal: "a\nx\nc\ny", selected: [0], to: r.original) == "a\nx\nc\nd", "partial acceptance")
do { _ = try revision("abc").applying(proposal: "axc", selected: [0], to: "ayc"); fatalError("overlap accepted") } catch {}
let selected = ManuscriptRevision(id: UUID(), relativePath: "draft.md", original: "앞😀뒤", selectionLocation: 1, selectionLength: 2)
check(try selected.applying(proposal: "한글", selected: [0], to: selected.original) == "앞한글뒤", "UTF16 range")
let invalid = ManuscriptRevision(id: UUID(), relativePath: "a", original: "a", selectionLocation: -1, selectionLength: 100)
do { _ = try invalid.applying(proposal: "b", selected: [0], to: "a"); fatalError("invalid range") } catch {}
let large = revision(Array(repeating: "line", count: 5000).joined(separator: "\n"))
check(large.changes(proposal: "new").count == 1, "bounded large diff")

func merged(_ base: String, _ current: String, _ proposed: String, _ expected: String, deletion: Bool = false) throws {
    check(try ManuscriptTextMerge.merge(base: base, current: current, proposed: proposed, allowingProposedDeletions: deletion) == expected, "merge: \(base) / \(current) / \(proposed)")
}
try merged("첫째\n둘째\n셋째", "앞에 삽입\n첫째\n둘째\n셋째", "첫째\nAI 수정\n셋째", "앞에 삽입\n첫째\nAI 수정\n셋째")
try merged("나는 사과를 먹고 그는 잔다.", "나는 배를 먹고 그는 잔다.", "나는 사과를 먹고 그는 걷는다.", "나는 배를 먹고 그는 걷는다.")
try merged("앞😀뒤\r\n마지막\r\n", "앞😀뒤\r\n끝\r\n", "앞한글뒤\r\n마지막\r\n", "앞한글뒤\r\n끝\r\n")
try merged("start\ndelete this\nend", "start\ndelete modified this\nend", "start\nend", "start\nend", deletion: true)
try merged("abc", "aXbc", "ac", "aXc", deletion: true)
try merged("abc", "abXc", "ac", "aXc", deletion: true)
try merged("a\nx\na\ny", "prefix\na\nx\na\ny", "a\nx\na\nZ", "prefix\na\nx\na\nZ")
try merged("abc", "aXbc", "aXbc", "aXbc")
for (base, current, proposed) in [("abc", "aXbc", "aYbc"), ("abc", "axc", "ayc"), ("start\nremove\nend", "start\nchanged\nend", "start\nend")] {
    do { _ = try ManuscriptTextMerge.merge(base: base, current: current, proposed: proposed); fatalError("conflict accepted") } catch {}
}
let movedSelection = ManuscriptRevision(id: UUID(), relativePath: "a", original: "앞😀뒤", selectionLocation: 1, selectionLength: 2)
check(try movedSelection.applying(proposal: "교체", selected: [0], to: "추가앞😀뒤") == "추가앞교체뒤", "inline selection rebases after prefix typing")

let book = (0..<100_000).map { "paragraph-\($0)" }.joined(separator: "\n")
let humanBook = book.replacingOccurrences(of: "paragraph-1\n", with: "human first\n").replacingOccurrences(of: "paragraph-99990\n", with: "human last\n")
let aiBook = book.replacingOccurrences(of: "paragraph-50000\n", with: "AI middle\n")
try merged(book, humanBook, aiBook, humanBook.replacingOccurrences(of: "paragraph-50000\n", with: "AI middle\n"))
print("PASS revision partial apply, blank lines, Unicode, stale and invalid guards, bounded diff")
'''
with tempfile.TemporaryDirectory(prefix='lore-revision-') as tmp:
    main = Path(tmp) / 'main.swift'; main.write_text(source + harness)
    subprocess.run(['xcrun','swiftc',str(root / 'TextlinkEditor/Services/FileSystem/Workspace/DocumentReconciliation.swift'),str(main),'-o',tmp+'/test'],check=True)
    subprocess.run([tmp+'/test'],check=True)
