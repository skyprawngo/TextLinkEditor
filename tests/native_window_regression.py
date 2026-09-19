#!/usr/bin/env python3
"""Verify bounded TextKit windows with complete document edits, selection and scroll anchors."""
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
let source = (0..<100_000).map { "행 \($0) 한글 👩‍💻 원고 abcdefghijklmnopqrstuvwxyz\n" }.joined()
let model = ManuscriptWindowDocument(source)
for edit in [NSRange(location: 0, length: 2), NSRange(location: 100, length: 7), NSRange(location: model.length - 3, length: 3)] {
    model.replace(edit, with: "😀\r\n가\n나")
    precondition(model.starts == ManuscriptWindowDocument.scan(model.text as NSString), "incremental line index must match full source")
}
let prepared = try PreparedManuscript.build(text: source, styleKey: "test", attributes: [:], buildsStorage: false)
precondition(prepared.takeStorage() == nil, "preparation must not allocate full attributed storage")
let view = NativeManuscriptTextView()
view.loadDocument(source, prepared: prepared)
let paging = view.windowedDocument!
precondition(view.string.utf16.count < source.utf16.count / 50)
precondition(view.documentText == source)
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.orderFront(nil)
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
window.makeFirstResponder(view)
func settle() {
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    window.displayIfNeeded()
}
settle()
for row in [600, 1100, 1600, 1100, 600, 100, 99_980, 0] {
    let anchor = EditorScrollCoordinator.Anchor(offset: paging.document.starts[row], screenY: 0)
    view.restoreDocumentAnchor(anchor)
    settle()
    let local = anchor.offset - paging.range.location
    let rect = view.lineRect(at: local)!
    let y = rect.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    precondition(abs(y) < 2, "global row \(row) moved by \(y) pixels after window transition")
    precondition(view.documentSelection == NSRange(location: 0, length: 0), "scroll must preserve offscreen caret")
    precondition(view.string == paging.document.substring(paging.range))
    let snapshot = view.documentViewportSnapshot()!
    precondition(snapshot.firstVisibleLine == row + 1, "saved position must be global: \(snapshot.firstVisibleLine) vs \(row+1)")
    precondition(view.lineStarts.count <= 769)
}
print("PASS 100000-line bounded storage and forward/backward/EOF viewport anchors")
// Actual threshold crossings keep the visible glyph fixed, and only insert the delta.
view.restoreDocumentAnchor(.init(offset: paging.document.starts[500], screenY: 0))
settle()
let beforeWindow = paging.range
let target = paging.document.starts[920]
let beforeInserted = paging.insertedUTF16Count
view.scrollCoordinator.restore(.init(offset: target - paging.range.location, screenY: 0))
settle()
paging.extendIfNeeded()
settle()
precondition(paging.range != beforeWindow, "near-edge scroll must advance window")
precondition(paging.insertedUTF16Count - beforeInserted < paging.range.length, "overlap must be retained")
precondition(view.documentText == source)
print("PASS threshold transition inserts only non-overlapping text")
view.selectDocumentPosition(line: 90_000, column: 4)
settle()
let edit = view.documentSelection
view.insertText("수정😀", replacementRange: NSRange(location: NSNotFound, length: 0))
let edited = view.documentText
precondition(edited != source && edited.contains("수정😀"))
view.restoreDocumentAnchor(.init(offset: 0, screenY: 0))
settle()
view.undo(nil)
precondition(view.documentText == source, "undo must use document coordinates after paging")
view.redo(nil)
precondition(view.documentText == edited)
precondition(view.documentSelection.location == edit.location + "수정😀".utf16.count)
print("PASS typing and global undo/redo after eviction")
view.execute(EditorCommand(.find("행 70000 ", forward: true)))
precondition((view.documentText as NSString).substring(with: view.documentSelection) == "행 70000 ")
view.selectAll(nil)
precondition(view.documentSelection.length == edited.utf16.count)
view.insertText("전체 교체", replacementRange: NSRange(location: NSNotFound, length: 0))
precondition(view.documentText == "전체 교체")
view.undo(nil)
precondition(view.documentText == edited)
let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
try view.documentText.write(to: url, atomically: true, encoding: .utf8)
let disk = try String(contentsOf: url, encoding: .utf8)
precondition(disk == edited)
try FileManager.default.removeItem(at: url)
print("PASS global search, select all, replace, undo, and complete-source disk save")
view.selectDocumentRange(NSRange(location: 10, length: 5))
view.restoreDocumentAnchor(.init(offset: paging.document.starts[50_000], screenY: 0))
precondition(view.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")), "copy stays available for an offscreen document selection")
view.selectDocumentPosition(line: 10_000, column: 2)
let beforeIME = view.documentText
view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
settle()
view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
precondition(!view.hasMarkedText())
view.undo(nil)
precondition(view.documentText == beforeIME, "a composition must undo as a single document edit")
view.selectDocumentPosition(line: 10_000, column: 0)
let selectionStart = view.documentSelection.location
for _ in 0..<900 { view.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:))) }
precondition(view.documentPosition(at: NSMaxRange(view.documentSelection)).line >= 10_899)
precondition(view.documentSelection.location == selectionStart)
precondition(view.lineStarts.count <= 769, "large selections must not pin old chunks")
view.insertText("선택교체", replacementRange: NSRange(location: NSNotFound, length: 0))
view.undo(nil)
precondition(view.documentText == beforeIME)
print("PASS IME composition undo and selection extending across multiple windows")
// A mouse drag may evict its starting paragraph without changing its document anchor.
view.restoreDocumentAnchor(.init(offset: paging.document.starts[600], screenY: 0))
settle()
let clickPoint = NSPoint(x: view.textContainerOrigin.x + 30, y: host.contentView.bounds.minY + 100)
let clickOffset = paging.range.location + view.characterIndexForInsertion(at: clickPoint)
let downPoint = view.convert(clickPoint, to: nil)
let dragPoint = view.convert(NSPoint(x: clickPoint.x, y: host.contentView.bounds.maxY + 120), to: nil)
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: downPoint, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
for number in 1...260 {
    NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseDragged, location: dragPoint, modifierFlags: [], timestamp: Double(number) * 0.02,
        windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!, atStart: false)
}
NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: dragPoint, modifierFlags: [], timestamp: 6,
    windowNumber: window.windowNumber, context: nil, eventNumber: 261, clickCount: 1, pressure: 0)!, atStart: false)
view.mouseDown(with: down)
precondition(view.documentSelection.location == clickOffset)
precondition(view.documentPosition(at: NSMaxRange(view.documentSelection)).line > 1_300)
precondition(view.lineStarts.count <= 769)
print("PASS drag selection retains its anchor across evicted chunks")
// Saved anchors use full-document rows, independent of the current projection.
precondition(paging.document.starts == ManuscriptWindowDocument.scan(view.documentText as NSString), "document index after undo")
precondition(view.lineStarts == ManuscriptWindowDocument.scan(view.string as NSString), "local index after drag")
let saved = view.documentViewportSnapshot()!
view.restoreDocumentAnchor(.init(offset: 0, screenY: 0))
view.reopenDocumentViewport(saved)
settle()
let restored = view.documentViewportSnapshot()!
precondition(restored.firstVisibleLine == saved.firstVisibleLine)
precondition(abs(restored.offsetWithinLine - saved.offsetWithinLine) < 2)
precondition(!host.hasVerticalScroller && !host.hasHorizontalScroller)
print("PASS hidden native scrollers and reopening a saved window")
let fence = "```swift\n" + String(repeating: "let value = 1\n", count: 2_000) + "```\n"
view.loadDocument(fence)
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
view.setMarkdownRendering(true)
view.selectDocumentPosition(line: 1_000, column: 2)
settle()
let local = view.selectedRange().location
precondition(view.textStorage!.attribute(MarkdownSourceStyling.semanticKey, at: local, effectiveRange: nil) as? String == "codeBlock")
let inline = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
view.installInlinePanel(inline)
view.restoreDocumentAnchor(.init(offset: 0, screenY: 0))
settle()
precondition(inline.isHidden && view.inlinePanel === inline)
view.selectDocumentPosition(line: 1_000, column: 2)
view.scrollCoordinator.revealSelection()
settle()
precondition(!inline.isHidden && view.inlinePanel === inline)
view.closeInlinePanel()
print("PASS Markdown block context and inline-panel anchors across windows")
view.selectAll(nil)
view.insertText(source, replacementRange: NSRange(location: NSNotFound, length: 0))
precondition(view.documentText == source && view.lineStarts.count <= 769)
view.undo(nil)
precondition(view.documentText == fence)
precondition(paging.document.text == beforeIME, "detached window must not observe a replacement document")
print("PASS large paste stays windowed and old document observers are detached")

'''

with tempfile.TemporaryDirectory(prefix='textlink-window-test-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=120)
