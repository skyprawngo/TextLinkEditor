#!/usr/bin/env python3
"""Use real registry + persisted shortcut manager + native editor together."""
from pathlib import Path
import subprocess, tempfile, re
root = Path(__file__).resolve().parents[1]
setup = (root / 'tests/native_editor_regression.py').read_text().split("\nharness = r'''", 1)[0]
exec(compile(setup, __file__, 'exec'))
prefix = prefix[:prefix.index('enum ShortcutAction')] + prefix[prefix.index('final class TextUndoHistoryManager'):]
manager = (root / 'TextlinkEditor/Services/Core/KeyboardShortcutManager.swift').read_text() + '\n' + (root / 'TextlinkEditor/Services/Core/Shortcuts/ShortcutModels.swift').read_text()
a = manager.index('    private var shortcutsFileURL: URL {')
b = manager.index('    private var registrationObserver', a)
manager = manager[:a] + '''    private var shortcutsFileURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("shortcuts.json")
    }
''' + manager[b:]
harness = r'''
setbuf(stdout, nil)
func expect(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name); print("PASS \(name)") }
let app = NSApplication.shared
let view = NativeManuscriptTextView()
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
window.makeFirstResponder(view)
let manager = KeyboardShortcutManager.shared
func key(_ text: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: 0)!
}
var events: [EditorToolBridge.Event] = []
view.toolBridge.onEvent = { events.append($0) }
let future = EditorToolRegistry.tool("example.future", "example.title", .edit, .text) { $0.toolFormat("bold") }
EditorToolRegistry.register(future)
let id = ShortcutAction(rawValue: future.id)
expect(manager.binding(for: id) != nil, "registering executable creates settings row automatically")
manager.setKey("b", modifiers: [.command, .control], for: id)
view.load("한글")
view.setSelectedRange(NSRange(location: 0, length: 2))
expect(view.performKeyEquivalent(with: key("b", [.command, .control])), "custom key dispatches newly registered operation")
expect(view.string == "**한글**", "registered operation edits actual native manuscript")
window.displayIfNeeded()
view.layoutSubtreeIfNeeded()
expect(events.first?.tool.name == future.id && events.first?.phase == .began && events.last?.phase == .ended,
       "new tool shares begin apply layout end lifecycle")
view.undo(nil)
expect(view.string == "한글", "registered tool retains native Undo")
manager.toggleEnabled(for: id)
expect(!view.performKeyEquivalent(with: key("b", [.command, .control])), "disabled registered binding cannot invoke tool")
view.setSelectedRange(NSRange(location: 0, length: 2))
view.execute(EditorCommand(.tool(future.id)))
expect(view.string == "**한글**", "toolbar command uses same registry independently of shortcut enabled state")
view.undo(nil)
view.isEditable = false
view.execute(EditorCommand(.tool(future.id)))
expect(view.string == "한글" && events.last?.outcome == .cancelled, "registered text tool shares read-only guard")
view.isEditable = true
var controls: [String] = []
view.onToolPresentation = { controls.append($0) }
for tool in EditorToolRegistry.tools where tool.impact == .presentation { view.execute(EditorCommand(.tool(tool.id))) }
expect(Set(controls) == ["markdownPreview", "font", "fontSize", "lineSpacing", "letterSpacing"], "registered parameter tools present their actual toolbar controls")
var requests: [String] = []
let observer = NotificationCenter.default.addObserver(forName: Notification.Name("aiDraftAction"), object: nil, queue: nil) { requests.append($0.object as! String) }
for tool in EditorToolRegistry.tools where tool.category == .ai && tool.id != "ai.inline" && tool.id != "ai.attachSelection" {
    view.execute(EditorCommand(.tool(tool.id)))
}
expect(requests.count == 5, "all five AI tools dispatch through registry once")
NotificationCenter.default.removeObserver(observer)
let inline = ShortcutAction(rawValue: "ai.inline")
manager.setKey("l", modifiers: [.command, .control], for: inline)
let inlineObserver = NotificationCenter.default.addObserver(forName: Notification.Name("editorInlineAI"), object: view, queue: nil) { _ in view.installInlinePanel(NSView()) }
expect(view.performKeyEquivalent(with: key("l", [.command, .control])) && view.inlinePanel != nil, "customized inline key opens panel")
let input = NSTextField(frame: NSRect(x: 12, y: 12, width: 120, height: 22))
view.inlinePanel!.addSubview(input)
window.makeFirstResponder(input)
expect(view.performKeyEquivalent(with: key("l", [.command, .control])) && view.inlinePanel == nil, "customized inline key closes from input field")
manager.toggleEnabled(for: inline)
expect(!view.performKeyEquivalent(with: key("l", [.command, .control])), "disabled inline key is not hardcoded")
NotificationCenter.default.removeObserver(inlineObserver)
expect(view.textLayoutManager != nil, "registered tools retain TextKit 2")
var routed: [String] = []
let routeObserver = NotificationCenter.default.addObserver(forName: EditorToolRegistry.executionRequested, object: nil, queue: nil) {
    routed.append($0.object as! String)
}
for id in EditorToolID.allCases { expect(EditorToolRegistry.requestExecution(id.rawValue), "UI routing accepts registered ID") }
expect(routed == EditorToolID.allCases.map(\.rawValue), "UI dispatch preserves each ID exactly once")
expect(!EditorToolRegistry.requestExecution("unknown.tool") && routed.count == EditorToolID.allCases.count, "UI routing rejects unknown IDs before notification")
NotificationCenter.default.removeObserver(routeObserver)
// Registry identity and preflight contracts are shared by all UI entry points.
expect(Set(EditorToolID.allCases.map(\.rawValue)).isSubset(of: Set(EditorToolRegistry.tools.map(\.id))), "every built-in ID resolves to one registered tool")
expect(Set(EditorToolRegistry.tools.map(\.id)).count == EditorToolRegistry.tools.count, "tool IDs are unique")
window.displayIfNeeded()
view.toolBridge.cancelPending()
events.removeAll()
view.setSelectedRange(NSRange(location: 0, length: 0))
for id in [EditorToolID.bold, .attachSelection, .collaborationComment] {
    events.removeAll()
    expect(EditorToolRegistry.perform(id.rawValue, on: view), "known tool is dispatched")
    expect(events.count == 2 && events.first?.phase == .began && events.last?.phase == .ended && events.last?.outcome == .cancelled,
           "missing selection ends once without executing a tool")
}
view.onToolPresentation = nil
events.removeAll()
EditorToolRegistry.perform(EditorToolID.font.rawValue, on: view)
expect(events.count == 2 && events.last?.outcome == .cancelled, "missing presentation receiver is not reported as applied")
events.removeAll()
expect(!EditorToolRegistry.perform("unknown.tool", on: view) && events.isEmpty, "unknown ID has no side effects")
print("TOOL REGISTRY REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-tool-registry-') as directory:
    directory = Path(directory)
    adapter = directory/'KeyboardShortcutManager.swift'; adapter.write_text(manager)
    main = directory/'main.swift'; main.write_text(prefix + harness)
    executable = directory/'test'
    subprocess.run(['swiftc', *markdown_flags(),'-O',*map(str,sources),str(adapter),str(main),'-o',str(executable)],check=True)
    subprocess.run([str(executable),str(directory)],check=True)
