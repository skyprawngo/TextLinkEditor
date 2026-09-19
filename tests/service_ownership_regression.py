#!/usr/bin/env python3
"""Verify extracted owners preserve recovery ordering, preference keys and undo semantics."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'TextlinkEditor/Services/Editor/Session/EditorRecoveryWriter.swift',
    root / 'TextlinkEditor/Services/Project/ProjectPreferencesStore.swift',
    root / 'TextlinkEditor/Models/Project.swift',
    root / 'TextlinkEditor/Services/Core/UndoSystem.swift',
    *sorted((root / 'TextlinkEditor/Services/Core/Undo').glob('*.swift')),
]
harness = r'''
import Foundation
// Only creation-template categories are irrelevant to these storage tests.
enum ProjectSection: CaseIterable { case draft }
let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("recovery.txt")
let writer = EditorRecoveryWriter()
var delivered: [String] = []
writer.write(asynchronously: true, operation: {
    try! "old".write(to: file, atomically: true, encoding: .utf8)
    return "old error"
}, completion: { delivered.append($0 ?? "old success") })
writer.write(asynchronously: false, operation: {
    try! "final".write(to: file, atomically: true, encoding: .utf8)
    return nil
}, completion: { delivered.append($0 ?? "final success") })
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(try! String(contentsOf: file, encoding: .utf8) == "final")
precondition(delivered == ["final success"], "Older async completion must not overwrite a newer result")
writer.write(asynchronously: true, operation: { "old project error" }, completion: { delivered.append($0!) })
writer.invalidateAndWait()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(delivered == ["final success"], "Project transition invalidates pending completion")
writer.write(asynchronously: true, operation: { "current error" }, completion: { delivered.append($0!) })
let deadline = Date().addingTimeInterval(2)
while delivered.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(delivered.last == "current error", "Current failures must still reach the owner")

let suite = "textlink.refactor.tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let preferences = ProjectPreferencesStore(defaults: defaults)
let project = Project(name: "검증", path: file.deletingLastPathComponent())
preferences.saveRecentProjects([project])
precondition(preferences.loadRecentProjects() == [project])
let persisted = try! JSONDecoder().decode([Project].self, from: defaults.data(forKey: "recentProjects")!)
precondition(persisted == [project], "Existing recent-project key and JSON schema remain compatible")
defaults.set(["/keep": Data([1]), "/remove": Data([2])], forKey: "projectBookmarks")
preferences.removeBookmarks(for: ["/remove"])
precondition((defaults.dictionary(forKey: "projectBookmarks") as? [String: Data]) == ["/keep": Data([1])])
precondition(!preferences.restoreAccess(to: URL(fileURLWithPath: "/missing")))

var text = "ab"
let textHistory = TextUndoHistory(workArea: .editor) { replacement, range, _ in
    text = (text as NSString).replacingCharacters(in: range, with: replacement)
}
textHistory.addTextInput("a", at: 0, originalSelectedRange: NSRange(location: 0, length: 0))
textHistory.addTextInput("b", at: 1, originalSelectedRange: NSRange(location: 1, length: 0))
precondition(textHistory.undo() && text.isEmpty, "Pending typing group remains one undo step")
precondition(textHistory.redo() && text == "ab")
var state = 2
let history = GenericUndoHistory<Int>(workArea: .editor, restoreState: { state = $0 })
history.registerAction(description: "change", undoState: 1, redoState: 2)
precondition(history.undo() && state == 1)
precondition(history.redo() && state == 2)
history.undo()
history.registerAction(description: "branch", undoState: 1, redoState: 3)
precondition(!history.canRedo)
print("SERVICE OWNERSHIP REGRESSIONS PASSED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-owners-') as directory:
    path = Path(directory)
    main = path / 'main.swift'
    main.write_text(harness)
    binary = path / 'test'
    subprocess.run(['swiftc', *map(str, sources), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(path)], check=True)
