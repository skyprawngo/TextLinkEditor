#!/usr/bin/env python3
"""Verify native mouse hit testing and minimal arrow-key caret scrolling."""
from pathlib import Path
from markdown_test_support import markdown_flags
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
engine = root / 'TextlinkEditor/Services/Editor/TextEngine'
views = root / 'TextlinkEditor/Views/MainEditor/EditorPanel/TextlinkTextView'
markdown_sources = sorted((root / 'TextlinkEditor/Services/Editor/Markdown').glob('*.swift'))
sources = [engine / name for name in ['TextDocument.swift', 'TextSelection.swift', 'ViewportManager.swift', 'EditorState.swift', 'EditorCommand.swift']]
sources += sorted((engine / 'EditorState').glob('*.swift'))
sources += [root / 'TextlinkEditor/Services/Core/EditorToolRegistry.swift']
sources += markdown_sources
sources += sorted((root / 'TextlinkEditor/Services/Editor/Scroll').glob('*.swift'))
sources += [root / 'TextlinkEditor/Services/FileSystem/Workspace/WorkspaceFileEvents.swift']
sources += [views / 'PreparedManuscript.swift', views / 'EditorToolBridge.swift', *sorted(views.glob('NativeManuscript*.swift'))]
prefix = (root / 'tests/editor_binding_regression.py').read_text().split("harness = r'''", 1)[1].split('final class Box', 1)[0]
harness = r'''
setbuf(stdout, nil)
_ = NSApplication.shared
let view = NativeManuscriptTextView()
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.orderFront(nil)

view.load(String(repeating: "abcdefghijklmnopqrstuvwxyz 원고입니다.\n", count: 100))
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
window.makeFirstResponder(view)
window.displayIfNeeded()
view.scrollCoordinator.cancel()
view.setSelectedRange(NSRange(location: 0, length: 0))
host.contentView.setBoundsOrigin(NSPoint(x: host.contentView.bounds.minX, y: 0))
view.needsLayout = true
window.displayIfNeeded()

func settle() {
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    window.displayIfNeeded()
}
func arrow(down: Bool) {
    let characters = down ? "\u{F701}" : "\u{F700}"
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: down ? 125 : 126)!
    view.keyDown(with: event)
}
for row in [2, 8, 16] {
    let offset = view.offset(line: row, column: 3)
    let rect = view.lineRect(at: offset)!
    let point = NSPoint(x: view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0) + 1, y: rect.midY + view.textContainerOrigin.y)
    let hostPoint = host.convert(point, from: view)
    precondition(host.hitTest(hostPoint) === view, "visible manuscript clicks must reach NSTextView")
    let expected = view.characterIndexForInsertion(at: point)
    let windowPoint = view.convert(point, to: nil)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0.01,
        windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    NSApp.postEvent(up, atStart: true)
    view.mouseDown(with: down)
    settle()
    precondition(view.selectedRange() == NSRange(location: expected, length: 0), "click must place the caret at the displayed text")
    let before = host.contentView.bounds.minY
    arrow(down: true)
    settle()
    precondition(abs(host.contentView.bounds.minY - before) < 1, "moving down inside viewport must not scroll")
    arrow(down: false)
    settle()
    precondition(abs(host.contentView.bounds.minY - before) < 1, "moving up inside viewport must not scroll")
}
print("PASS mouse caret placement and arrow movement inside viewport")
// Follow only when crossing the visible bottom or top line.
view.setSelectedRange(NSRange(location: view.offset(line: 16, column: 3), length: 0))
var crossedBottom = false
for _ in 0..<20 {
    let before = host.contentView.bounds.minY
    arrow(down: true)
    let caret = view.lineRect(at: view.selectedRange().location)!
        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    settle()
    let after = host.contentView.bounds.minY
    if caret.maxY <= before + host.contentView.bounds.height - host.contentView.contentInsets.bottom {
        precondition(abs(after - before) < 1, "visible bottom row must not trigger scroll")
    } else {
        precondition(after > before && after - before <= caret.height + 2, "bottom crossing must scroll only one line")
        crossedBottom = true
        break
    }
}
precondition(crossedBottom)
host.contentView.setBoundsOrigin(NSPoint(x: host.contentView.bounds.minX, y: 200))
view.needsLayout = true
settle()
view.setSelectedRange(NSRange(location: view.offset(line: 20, column: 3), length: 0))
var crossedTop = false
for _ in 0..<40 {
    let before = host.contentView.bounds.minY
    arrow(down: false)
    let caret = view.lineRect(at: view.selectedRange().location)!
        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    settle()
    let after = host.contentView.bounds.minY
    if caret.minY >= before {
        precondition(abs(after - before) < 1, "visible top row must not trigger scroll")
    } else {
        precondition(after < before && before - after <= caret.height + 2, "top crossing must scroll only one line")
        crossedTop = true
        break
    }
}
precondition(crossedTop)
print("PASS caret follows only across viewport boundaries")
let savedSelection = view.selectedRange()
EditorFocusCoordinator.claimSidebar(in: window)
precondition(window.firstResponder !== view, "sidebar selection must resign manuscript focus")
precondition(view.selectedRange() == savedSelection, "sidebar focus preserves caret offset")
precondition(!EditorFocusCoordinator.permitsAutomaticFocus(in: window))
let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
EditorFocusCoordinator.claimSidebar(in: otherWindow)
precondition(!EditorFocusCoordinator.permitsAutomaticFocus(in: window), "another window cannot release sidebar ownership")
EditorFocusCoordinator.claimEditor(in: otherWindow)
precondition(!EditorFocusCoordinator.permitsAutomaticFocus(in: window))
EditorFocusCoordinator.claimEditor(in: window)
let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 50))
host.addSubview(composer)
precondition(window.makeFirstResponder(composer))
precondition(!EditorFocusCoordinator.permitsAutomaticFocus(in: window), "loading a document cannot steal AI input focus")
let rename = NSTextField(frame: NSRect(x: 0, y: 60, width: 150, height: 24))
host.addSubview(rename)
precondition(window.makeFirstResponder(rename))
precondition(!EditorFocusCoordinator.permitsAutomaticFocus(in: window), "shared field editor protects rename and toolbar input")
window.makeFirstResponder(view)
composer.removeFromSuperview()
rename.removeFromSuperview()
print("PASS window-local intent and actual input responder protect asynchronous focus")
view.load("# 큰 제목\n\n본문 한글 😀\n")
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
view.scrollCoordinator.cancel()
host.contentView.setBoundsOrigin(.zero)
settle()
let caretRange = NSRange(location: 4, length: 0)
view.setSelectedRange(caretRange)
var plainRect = NSRect.zero
for enabled in [false, true, false, true, false] {
    view.setMarkdownRendering(enabled)
    settle()
    view.scrollCoordinator.cancel()
    host.contentView.setBoundsOrigin(.zero)
    settle()
    let rect = view.firstRect(forCharacterRange: caretRange, actualRange: nil)
    precondition(view.selectedRange() == caretRange, "format toggle must preserve source caret offset")
    precondition(rect.height > 0 && rect.minY.isFinite, "caret geometry must remain valid")
    if !enabled {
        if plainRect != .zero { precondition(abs(rect.height - plainRect.height) < 1, "plain mode restores caret height") }
        plainRect = rect
    } else {
        precondition(rect.height > plainRect.height, "formatted heading updates caret height immediately")
    }
}
print("PASS sidebar resigns focus and formatting toggles update caret geometry without changing selection")
view.setMarkdownRendering(false)
let manuscript = (1...240).map { $0 % 3 == 0 ? "# 제목 \($0)" : "본문 \($0) 한글과 **강조**" }.joined(separator: "\n")
view.load(manuscript)
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
let preservedCaret = NSRange(location: view.offset(line: 115, column: 3), length: 0)
view.setSelectedRange(preservedCaret)
view.scrollCoordinator.revealSelection()
settle()
view.scrollCoordinator.cancel()
let targetY = host.contentSize.height * 0.6
view.scrollCoordinator.restore(.init(offset: preservedCaret.location, screenY: targetY))
view.needsLayout = true
settle()
view.scrollCoordinator.cancel()
for enabled in [true, false, true, false] {
    let before = view.lineRect(at: preservedCaret.location)!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    precondition(abs(before - targetY) < 1, "fixture cursor must start at 60 percent")
    view.setMarkdownRendering(enabled)
    settle()
    let after = view.lineRect(at: preservedCaret.location)!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    precondition(view.selectedRange() == preservedCaret, "format toggle must keep line 116 and its column")
    precondition(abs(after - before) < 1, "format toggle must keep the cursor at 60 percent of the viewport")
    precondition(view.string == manuscript, "format toggle must preserve manuscript")
}
print("PASS repeated formatting toggles preserve line 116 at 60 percent of viewport")

'''

with tempfile.TemporaryDirectory(prefix='textlink-scroll-test-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
