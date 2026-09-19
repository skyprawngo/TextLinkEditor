#!/usr/bin/env python3
"""Measure the production diff row's SwiftUI layout at constrained widths."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / 'TextlinkEditor/Views/MainEditor/Sidebar/CommitDiffView.swift').read_text()
# Expose only visibility for the harness; the production row body is unchanged.
view = view.replace('private func row(', 'func row(')
harness = r'''
import AppKit
import SwiftUI
enum L10n { static func get(_ key: String) -> String { key } }
let app = NSApplication.shared
let patch = "diff --git a/test.md b/test.md\n--- a/test.md\n+++ b/test.md\n@@ -1 +1 @@\n-old\n+new\n"
let document = CommitDiffDocument(patch: patch)
var expansion = CommitDiffExpansionState()
precondition(expansion.allExpanded)
expansion.toggle(document: document)
precondition(!expansion.allExpanded && expansion.collapsedFiles.count == 1 && expansion.collapsedHunks.count == 1)
expansion.toggle(document: document)
precondition(expansion.allExpanded)
expansion.collapsedHunks.insert(document.files[0].hunks[0].id)
precondition(!expansion.allExpanded)
expansion.toggle(document: document)
precondition(expansion.allExpanded, "mixed state must expand both files and hunks")
print("PASS expansion toggle: expanded, collapsed, mixed")
let view = CommitDiffView(patch: "", close: {})
func height(_ text: String, width: CGFloat) -> CGFloat {
    let line = CommitDiffDocument.Line(id: 0, text: text, kind: .added, oldNumber: nil, newNumber: 1)
    let host = NSHostingView(rootView: view.row(line).frame(width: width).fixedSize(horizontal: false, vertical: true))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}
let sentence = "+" + String(repeating: "긴 문장은 파일 컨테이너의 너비에 맞춰 줄바꿈되어야 합니다. ", count: 10)
let wide = height(sentence, width: 800), narrow = height(sentence, width: 400)
precondition(narrow > wide && wide > height("+짧은 행", width: 400), "long diff lines must grow vertically as the container narrows")
let token = "+" + String(repeating: "abcdefghij", count: 80)
precondition(height(token, width: 400) > height(token, width: 800), "unbroken content must wrap rather than overflow")
print("PASS diff rows wrap Korean prose and unbroken text at container width")
'''
with tempfile.TemporaryDirectory(prefix='commit-diff-layout-') as tmp:
    tmp = Path(tmp)
    (tmp / 'View.swift').write_text(view)
    (tmp / 'main.swift').write_text(harness)
    executable = tmp / 'test'
    subprocess.run(['swiftc', str(root / 'TextlinkEditor/Views/SheetHeader.swift'), str(root / 'TextlinkEditor/Services/Versions/CommitDiffDocument.swift'), str(tmp / 'View.swift'), str(tmp / 'main.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
