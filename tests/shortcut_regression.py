#!/usr/bin/env python3
"""Test the production shortcut matcher with its JSON path redirected to a temp dir.

Only shortcutsFileURL's body is replaced in a temporary source copy. No production
preferences, Application Support files, or manager behavior are replaced.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'TextlinkEditor/Services/Core/KeyboardShortcutManager.swift').read_text()
source += '\n' + (root / 'TextlinkEditor/Services/FileSystem/SidebarPathCopy.swift').read_text()
start = source.index('    private var shortcutsFileURL: URL {')
end = source.index('    private var registrationObserver', start)
source = source[:start] + '''    private var shortcutsFileURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shortcuts.json")
    }

''' + source[end:]
harness = r'''
import Foundation
import AppKit
import SwiftUI

enum L10n { static func get(_ key: String) -> String { key } }
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { print("FAIL \(name)"); exit(1) }
    print("PASS \(name)")
}
func event(_ code: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code)!
}
let project = URL(fileURLWithPath: "/tmp/작품.weaveproj")
let file = project.appendingPathComponent("원고/첫 장.md")
expect(SidebarPathCopy.path(for: file, relativeTo: nil) == "/tmp/작품.weaveproj/원고/첫 장.md", "absolute path preserves Korean and spaces")
expect(SidebarPathCopy.path(for: file, relativeTo: project) == "원고/첫 장.md", "relative path starts at project root")
expect(SidebarPathCopy.path(for: project.appendingPathComponent("원고"), relativeTo: project) == "원고", "folder relative path")
expect(SidebarPathCopy.path(for: project, relativeTo: project) == ".", "project root relative path")
expect(SidebarPathCopy.path(for: URL(fileURLWithPath: "/tmp/작품.weaveproj-other/file"), relativeTo: project) == nil, "sibling prefix cannot masquerade as project child")
let manager = KeyboardShortcutManager.shared
expect(manager.action(matching: event(8, "c", [.command, .option, .shift])) == .copyPath, "copy path default")
expect(manager.action(matching: event(8, "C", [.command, .option])) == .copyRelativePath, "relative path default")
expect(manager.action(matching: event(36, "\r")) == .renameItem, "sidebar rename default")
manager.setKey("c", modifiers: [.control, .option], for: .copyPath)
manager.loadShortcuts()
expect(manager.action(matching: event(8, "c", [.command, .option, .shift])) == .copyPath, "previous path shortcut migrates to command")
manager.setKey("p", modifiers: [.command, .shift], for: .copyPath)
manager.loadShortcuts()
expect(manager.action(matching: event(35, "p", [.command, .shift])) == .copyPath, "custom path shortcut survives migration")
manager.resetToDefault(for: .copyPath)
manager.setKey("c", modifiers: [.command, .option], for: .copyPath)
manager.setKey("c", modifiers: [.command, .option, .shift], for: .copyRelativePath)
manager.loadShortcuts()
expect(manager.action(matching: event(8, "c", [.command, .option])) == .copyRelativePath, "previous command defaults swap together")
manager.loadShortcuts()
expect(manager.action(matching: event(8, "c", [.command, .option, .shift])) == .copyPath, "swapped defaults remain stable on reload")



expect(manager.action(matching: event(126, "\u{f700}", [.option, .function, .numericPad])) == .moveLineUp, "default option up with system flags")
expect(manager.action(matching: event(125, "\u{f701}", .option)) == .moveLineDown, "default option down")
expect(manager.action(matching: event(126, "\u{f700}", [.option, .shift])) == .duplicateLineUp, "shift selects duplicate")
expect(manager.action(matching: event(126, "\u{f700}", [.option, .control])) == nil, "extra modifier prevents match")
expect(manager.action(matching: event(51, "\u{7f}", .option)) == .deleteWordBackward, "option backspace")
expect(manager.action(matching: event(51, "\u{7f}", .command)) == .deleteToLineStart, "command backspace")
manager.setKey("k", modifiers: [.control, .shift], for: .moveLineUp)
expect(manager.action(matching: event(40, "K", [.control, .shift, .capsLock])) == .moveLineUp, "reassigned uppercase key with caps lock")
expect(manager.action(matching: event(126, "\u{f700}", .option)) == nil, "old binding no longer matches")
manager.toggleEnabled(for: .moveLineUp)
expect(manager.action(matching: event(40, "K", [.control, .shift])) == nil, "disabled binding ignored")
manager.loadShortcuts()
expect(manager.binding(for: .moveLineUp)?.isEnabled == false, "disabled state persisted in temp JSON")
manager.toggleEnabled(for: .moveLineUp)
manager.loadShortcuts()
expect(manager.action(matching: event(40, "K", [.control, .shift])) == .moveLineUp, "custom key reloads from temp JSON")
let special: [(String, UInt16, String)] = [
    ("space", 49, " "), ("escape", 53, "\u{1b}"), ("esc", 53, "\u{1b}"),
    ("home", 115, "\u{f729}"), ("end", 119, "\u{f72b}"),
    ("pageup", 116, "\u{f72c}"), ("pagedown", 121, "\u{f72d}"),
    ("left", 123, "\u{f702}"), ("right", 124, "\u{f703}"),
    ("delete", 51, "\u{7f}"), ("backspace", 51, "\u{7f}"),
    ("enter", 76, "\u{3}"), ("return", 36, "\r"), ("tab", 48, "\t")
]
for (key, code, text) in special {
    manager.setKey(key, modifiers: [.control, .option, .command], for: .moveLineUp)
    expect(manager.action(matching: event(code, text, [.control, .option, .command, .function])) == .moveLineUp,
           "special key \(key)")
}
manager.setKey("esc", modifiers: [.control, .option, .command], for: .moveLineUp)
expect(manager.findConflict(key: "escape", modifiers: [.control, .option, .command], excluding: .moveLineDown)?.action == .moveLineUp,
       "equivalent aliases share conflict detection")
manager.resetToDefault(for: .moveLineUp)
expect(manager.action(matching: event(126, "\u{f700}", .option)) == .moveLineUp, "reset restores default")
expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shortcuts.json").path), "all persistence uses temp directory")
let preview = ShortcutAction(rawValue: "display.markdownPreview")
expect(manager.binding(for: preview)?.key == "", "Markdown preview tool appears as configurable unassigned shortcut")
manager.setKey("m", modifiers: [.command, .control], for: preview)
manager.loadShortcuts()
expect(manager.action(matching: event(46, "m", [.command, .control])) == preview, "Markdown preview shortcut persists and resolves")
expect(manager.toolHelpText("display.markdownPreview") == "editor.markdown.toggle (⌃⌘M)", "tool help uses the current registered shortcut")
expect(manager.binding(for: preview)?.menuKeyEquivalent == "m", "context menu receives the configured key equivalent")
manager.toggleEnabled(for: preview)
expect(manager.toolHelpText("display.markdownPreview") == "editor.markdown.toggle", "disabled shortcuts are omitted from tool help")
manager.toggleEnabled(for: preview)
let inline = ShortcutAction(rawValue: "ai.inline")
expect(manager.action(matching: event(34, "i", [.command])) == inline, "registered inline tool supplies default shortcut")
expect(manager.action(matching: event(34, "i", [.command, .option])) == nil, "previous inline default is unassigned")
manager.setKey("l", modifiers: [.command, .control], for: inline)
manager.loadShortcuts()
expect(manager.binding(for: inline)?.key == "l", "saved inline customization survives reload")
expect(manager.action(matching: event(34, "i", [.command])) == nil, "inline old key is removed after reassignment")
expect(manager.action(matching: event(37, "l", [.command, .control])) == inline, "inline uses customized key")
manager.toggleEnabled(for: inline)
expect(manager.action(matching: event(37, "l", [.command, .control])) == nil, "inline disabled key does not match")
manager.resetToDefault(for: inline)
expect(manager.action(matching: event(34, "i", [.command])) == inline, "inline reset adopts command I")
expect(EditorToolRegistry.tools.allSatisfy { manager.binding(for: ShortcutAction(rawValue: $0.id)) != nil }, "every registered tool appears in settings source even without a key")
let future = EditorToolRegistry.tool("future.example", "future.title", .edit, .text) { $0.toolFormat("bold") }
EditorToolRegistry.register(future)
let futureID = ShortcutAction(rawValue: future.id)
expect(manager.binding(for: futureID)?.key == "", "one tool registration automatically adds unassigned shortcut row")
expect(futureID.displayName == "future.title", "registered title is used without settings switch")
manager.setKey("9", modifiers: [.command, .option], for: futureID)
manager.loadShortcuts()
expect(manager.action(matching: event(25, "9", [.command, .option])) == futureID, "new tool customization persists and routes without action enum changes")
let unknown = ShortcutBinding(action: ShortcutAction(rawValue: "future.uninstalled"), key: "x", modifiers: .control, isEnabled: false)
let persisted = try! JSONEncoder().encode([manager.binding(for: .moveLineUp)!, unknown])
let persistedURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shortcuts.json")
try! persisted.write(to: persistedURL)
manager.loadShortcuts()
expect(manager.binding(for: unknown.action) == unknown, "unknown future IDs round trip without resetting user settings")
expect(manager.binding(for: futureID) != nil, "loading old settings merges new tools")
EditorToolRegistry.register(EditorToolRegistry.tool("future.conflict", "future.conflict", .edit, .text, key: "s", modifiers: .command) { $0.toolFormat("italic") })
expect(manager.binding(for: ShortcutAction(rawValue: "future.conflict"))?.key == "", "new default cannot steal existing save shortcut")
print("ALL SHORTCUT REGRESSIONS PASSED")
'''
with tempfile.TemporaryDirectory(prefix='lore-shortcut-tests-') as directory:
    directory = Path(directory)
    adapter = directory / 'KeyboardShortcutManager.swift'
    adapter.write_text(source)
    main = directory / 'main.swift'
    main.write_text(harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', str(root / 'TextlinkEditor/Services/Core/EditorToolRegistry.swift'), str(adapter), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(directory)], check=True)
