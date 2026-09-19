#!/usr/bin/env python3
"""Exercise native rename completion callbacks without changing user files."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'TextlinkEditor/Views/Components/SelectableTextField.swift').read_text().split('#Preview')[0]
row_source = (root / 'TextlinkEditor/Views/MainEditor/Sidebar/ProjectExplorer/FileSystemItemRow.swift').read_text()
finish_method = row_source.split('    private func finishEditing() {', 1)[1].split('    private func cancelEditing()', 1)[0]
source += r'''
final class RenameItem { var name = "original.md" }
final class RenameManager {
    var calls = 0
    var duringRename: (() -> Void)?
    func rename(_ item: RenameItem, to name: String) -> Bool {
        calls += 1
        let callback = duringRename
        duringRename = nil
        callback?()
        return true
    }
}
final class RenameRow {
    var isEditing = true
    var isTextFieldFocused = true
    var editingName = "changed.md"
    let item = RenameItem()
    let fileSystemManager = RenameManager()
    var onCacheUpdate: (() -> Void)?
''' + '    func finishEditing() {' + finish_method + '\n}\n'
harness = r'''
let row = RenameRow()
row.fileSystemManager.duringRename = { row.finishEditing() }
row.finishEditing()
row.finishEditing()
precondition(row.fileSystemManager.calls == 1, "Rename must be single-shot across reentrant and late callbacks")
let app = NSApplication.shared
var name = "original.md"
var commits = 0
var cancellations = 0
var exits = 0
var allowExit = true
let wrapper = SelectableTextField(
    text: Binding(get: { name }, set: { name = $0 }), selectRange: 0..<8,
    onCommit: { commits += 1 }, onCancel: { cancellations += 1 },
    onFocusLost: { exits += 1; return allowExit })
let field = NSTextField()
let editor = NSTextView()
let notification = Notification(name: NSControl.textDidEndEditingNotification, object: field)
let commit = wrapper.makeCoordinator()
precondition(commit.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
commit.controlTextDidEndEditing(notification)
precondition(commits == 1 && exits == 0, "Enter must apply exactly once, never discard")
let cancel = wrapper.makeCoordinator()
precondition(cancel.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
cancel.controlTextDidEndEditing(notification)
precondition(cancellations == 1 && exits == 0, "Escape must not also submit or prompt")
let outside = wrapper.makeCoordinator()
outside.controlTextDidEndEditing(notification)
outside.controlTextDidEndEditing(notification)
precondition(exits == 1 && commits == 1, "Focus loss must request exit once, never submit")
allowExit = false
let resume = wrapper.makeCoordinator()
resume.controlTextDidEndEditing(notification)
precondition(!resume.hasEnded, "Cancelling discard must keep the editing session")
precondition(resume.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
precondition(commits == 2, "Enter must still apply after declining discard")
print("SIDEBAR RENAME CALLBACK REGRESSIONS PASSED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-rename-') as temp:
    swift = Path(temp) / 'main.swift'
    binary = Path(temp) / 'regression'
    swift.write_text(source + harness)
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
