#!/usr/bin/env python3
"""Verify shared tool lifecycle, attribute deltas, undo and large-document layout."""
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
sources += [views / name for name in ['PreparedManuscript.swift', 'EditorToolBridge.swift']]
sources += sorted(views.glob('NativeManuscript*.swift'))
prefix = (root / 'tests/editor_binding_regression.py').read_text().split("harness = r'''", 1)[1].split('final class Box', 1)[0]
harness = r'''
setbuf(stdout, nil)
func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); print("PASS \(message)") }
let app = NSApplication.shared
let view = NativeManuscriptTextView()
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.makeFirstResponder(view)
window.orderFront(nil)
view.load("**원고**")
view.setSelectedRange(NSRange(location: 2, length: 2))
var requestedPreview = false
view.onToolPresentation = { requestedPreview = $0 == "markdownPreview" }
let beforePreviewSelection = view.selectedRange()
view.execute(EditorCommand(.tool("display.markdownPreview")))
expect(requestedPreview && view.string == "**원고**" && view.selectedRange() == beforePreviewSelection, "registered preview tool preserves source and selection")
expect(view.undoManager?.canUndo == false, "preview tool does not create a manuscript undo entry")
let manager = view.textLayoutManager!
// Match the production selection delegate. Markdown marker visibility must not
// reflow paragraphs underneath AppKit's range-selection geometry.
final class MarkdownSelectionDelegate: NSObject, NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        (notification.object as? NativeManuscriptTextView)?.refreshMarkdownRendering()
    }
}
let selectionDelegate = MarkdownSelectionDelegate()
view.delegate = selectionDelegate
let selectionSource = "# **긴 제목 한글 😀**\n\n## **작품의 방향**\n\n" + String(repeating: "도시 생활과 던전 산업을 설명하는 긴 문장입니다. ", count: 12) + "\n\n## **던전과 공략**\n\n마지막 문단"
view.load(selectionSource)
view.applyDisplayStyle(.init(fontName: "Menlo", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
view.setSelectedRange(.init(location: 0, length: 0))
view.setMarkdownRendering(true)
window.displayIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
window.displayIfNeeded()
let selectionStart = (selectionSource as NSString).range(of: "도시 생활").location + 3
let selectionEnd = (selectionSource as NSString).range(of: "던전과 공략").location + 6
let initialLines = view.visibleManuscriptLines().map { $0.1 }
var selectionStyleEdits = 0
let selectionObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: nil) { _ in selectionStyleEdits += 1 }
for range in [NSRange(location: selectionStart, length: 8),
              NSRange(location: selectionStart, length: selectionEnd - selectionStart),
              NSRange(location: 3, length: selectionEnd - 3)] {
    view.setSelectedRange(range, affinity: .downstream, stillSelecting: true)
    view.refreshMarkdownRendering() // SwiftUI configuration after publishing selection.
    window.displayIfNeeded()
    expect(view.selectedRange() == range, "Markdown range selection retains source coordinates")
    expect(view.visibleManuscriptLines().map { $0.1 } == initialLines, "Markdown range selection retains rendered line geometry")
}
expect(selectionStyleEdits == 0, "extending Markdown selection never rewrites layout attributes")
view.setSelectedRange(.init(location: selectionStart, length: 0))
expect(selectionStyleEdits > 0, "returning to a caret refreshes active-paragraph Markdown markers")
NotificationCenter.default.removeObserver(selectionObserver)
expect(view.string == selectionSource && view.undoManager?.canUndo == false, "selection presentation preserves manuscript and Undo")
view.delegate = nil
view.setMarkdownRendering(false)
var events: [EditorToolBridge.Event] = []
view.toolBridge.onEvent = { events.append($0) }
func verifyCompleted(_ name: String) {
    expect(events.map(\.phase) == [.began, .validated, .applied, .viewportLaidOut, .ended], "\(name) shares the full layout lifecycle")
    expect(Set(events.map(\.id)).count == 1 && events.last?.outcome == .applied, "\(name) completes one identified operation")
    events.removeAll()
}
let text = String(repeating: "한글 원고 😀 글꼴과 줄간격과 자간 변경을 즉시 반영합니다. 긴 문장 줄바꿈 검증입니다.\n", count: 100000)
view.load(text)
view.applyDisplayStyle(.init(fontName: "SF Pro", fontSize: 14, lineHeightMultiple: 1, letterSpacing: 0))
window.displayIfNeeded()
view.setSelectedRange(NSRange(location: view.offset(line: 90000, column: 2), length: 0))
view.scrollRangeToVisible(view.selectedRange())
window.displayIfNeeded()
events.removeAll()
var edits = 0
let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: nil) { _ in edits += 1 }
let cases: [(String, EditorDisplayStyle)] = [
    ("font", .init(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1, letterSpacing: 0)),
    ("size", .init(fontName: "Menlo", fontSize: 18, lineHeightMultiple: 1, letterSpacing: 0)),
    ("lineSpacing", .init(fontName: "Menlo", fontSize: 18, lineHeightMultiple: 1.5, letterSpacing: 0)),
    ("letterSpacing", .init(fontName: "Menlo", fontSize: 18, lineHeightMultiple: 1.5, letterSpacing: 1.5))]
for (name, style) in cases {
    let selection = view.selectedRange()
    edits = 0
    let start = CFAbsoluteTimeGetCurrent()
    view.applyDisplayStyle(style)
    let applied = CFAbsoluteTimeGetCurrent()
    expect(edits == 1, "\(name) batches attributes into one storage edit")
    window.displayIfNeeded()
    print("TIME \(name): apply \((applied-start)*1000) ms, viewport \((CFAbsoluteTimeGetCurrent()-applied)*1000) ms")
    verifyCompleted(name)
    expect(view.selectedRange() == selection && !view.visibleManuscriptLines().isEmpty, "\(name) preserves selection and a populated viewport")
    let attributes = view.textStorage!.attributes(at: selection.location, effectiveRange: nil)
    expect((attributes[.font] as? NSFont)?.pointSize == style.fontSize, "\(name) applies glyph font size")
    expect((view.typingAttributes[.font] as? NSFont)?.fontName == NSFont(name: style.fontName, size: style.fontSize)?.fontName,
           "\(name) uses the requested typing font family")
    expect((attributes[.kern] as? NSNumber)?.doubleValue == Double(style.letterSpacing), "\(name) applies tracking")
    expect((attributes[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple == style.lineHeightMultiple, "\(name) applies paragraph spacing")
}

// Cursor above/below the viewport must be placed at the top before style mutation.
func cursorScreenY() -> CGFloat {
    guard let rect = view.lineRect(at: view.selectedRange().location) else { return -.infinity }
    return rect.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
}
for row in [9, 90000] {
    view.setSelectedRange(NSRange(location: view.offset(line: row, column: 2), length: 0))
    view.scrollRangeToVisible(NSRange(location: view.offset(line: row == 9 ? 99 : 100, column: 0), length: 0))
    window.displayIfNeeded()
    var relocatedBeforeMutation = false
    view.toolBridge.perform(.init(name: "anchorProbe", category: .presentation, effects: [.layout])) {
        relocatedBeforeMutation = abs(cursorScreenY()) < 1
        return true
    }
    window.displayIfNeeded()
    expect(relocatedBeforeMutation, "offscreen cursor row \(row + 1) reaches top before mutation")
    for (_, style) in cases {
        view.applyDisplayStyle(style)
        window.displayIfNeeded()
        print("ANCHOR row \(row + 1) y \(cursorScreenY())")
        expect(abs(cursorScreenY()) < 1, "cursor row \(row + 1) stays at top through font/size/spacing changes")
    }
}
view.setSelectedRange(NSRange(location: view.offset(line: 90003, column: 2), length: 0))
window.displayIfNeeded()
let visibleCursorY = cursorScreenY()
expect(visibleCursorY > 0 && visibleCursorY < host.contentSize.height, "visible cursor fixture is below viewport top")
view.applyDisplayStyle(cases[0].1)
window.displayIfNeeded()
expect(abs(cursorScreenY() - visibleCursorY) < 1, "visible cursor retains its screen position after reflow")
for size in [15.0, 16, 17, 16, 15] {
    view.applyDisplayStyle(.init(fontName: "Menlo", fontSize: size, lineHeightMultiple: 1.25, letterSpacing: 0.3))
}
window.displayIfNeeded()
print("SCRUB anchor before \(visibleCursorY), after \(cursorScreenY())")
expect(abs(cursorScreenY() - visibleCursorY) < 1, "continuous style scrubbing preserves cursor anchor before the next frame")

view.applyDisplayStyle(cases.last!.1)
window.displayIfNeeded()
events.removeAll()
NotificationCenter.default.removeObserver(observer)
let lastStyle = cases.last!.1
view.applyDisplayStyle(lastStyle)
expect(events.isEmpty, "unchanged SwiftUI configuration does not dispatch another tool")
expect(view.string == text, "presentation tools never change manuscript bytes")
let delta = EditorDisplayStyle(fontName: "Menlo", fontSize: 18, lineHeightMultiple: 1.5, letterSpacing: 2).changedAttributes(from: lastStyle)
expect(Set(delta.keys) == [.kern], "tracking delta does not reset fallback fonts or paragraphs")
view.setSelectedRange(NSRange(location: 0, length: 0))
view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
view.applyDisplayStyle(.init(fontName: "Menlo", fontSize: 18, lineHeightMultiple: 1.5, letterSpacing: 2))
window.displayIfNeeded()
expect(view.hasMarkedText(), "presentation tools preserve ongoing IME composition")
view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
view.undo(nil)
expect(view.string == text, "composition and Undo survive presentation changes")
for (type, prefix) in [(MarkdownFormatType.bold, "**"), (.italic, "*"), (.underline, "<u>"), (.strikethrough, "~~")] {
    view.setSelectedRange(NSRange(location: 0, length: 5))
    events.removeAll()
    view.execute(EditorCommand(.format(type)))
    window.displayIfNeeded()
    verifyCompleted("format.\(type)")
    expect(view.string.hasPrefix(prefix), "format.\(type) preserves markdown semantics")
    view.undo(nil)
    expect(view.string == text, "format.\(type) is one undo operation")
}
view.setSelectedRange(NSRange(location: 0, length: 0))
events.removeAll()
view.execute(EditorCommand(.format(.bold)))
expect(events.map(\.phase) == [.began, .validated, .applied, .ended] && events.last?.outcome == .unchanged, "empty selection finishes without scheduling layout")
view.isEditable = false
events.removeAll()
view.execute(EditorCommand(.replace("한글", replacement: "changed", all: true)))
expect(events.map(\.phase) == [.began, .ended] && events.last?.outcome == .cancelled, "read-only edits rejected at the shared entry point")
view.isEditable = true
var drafts = 0
let draftObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aiDraftAction"), object: nil, queue: nil) { _ in drafts += 1 }
events.removeAll()
view.execute(EditorCommand(.assistantDraft("test request")))
expect(drafts == 1 && events.map(\.phase) == [.began, .validated, .applied, .ended], "assistant dispatch shares lifecycle without reflow")
NotificationCenter.default.removeObserver(draftObserver)
events.removeAll()
let custom = EditorToolDescriptor(name: "futureTool", category: .presentation, effects: [.layout])
view.toolBridge.perform(custom) { true }
view.load("replacement document")
expect(events.last?.phase == .ended && events.last?.outcome == .cancelled, "document replacement cancels outstanding tool completion")
events.removeAll()
var nestedRan = false
view.toolBridge.onEvent = { event in
    events.append(event)
    if event.phase == .began && event.tool.name == "outer" {
        view.toolBridge.perform(.init(name: "nested", category: .assistant, effects: [])) { nestedRan = true; return true }
    }
}
view.toolBridge.perform(.init(name: "outer", category: .assistant, effects: [])) { true }
expect(!nestedRan && events.filter { $0.tool.name == "nested" }.last?.outcome == .cancelled, "observer cannot reenter tool mutation")
view.toolBridge.onEvent = { events.append($0) }
events.removeAll()
view.toolBridge.perform(custom) { true }
// External reload and inline AI apply share first-visible-line anchoring.
let externalBase = (1...150).map { "row \($0) 한글 😀" }.joined(separator: "\n")
for undoable in [false, true] {
    view.load(externalBase)
    view.applyDisplayStyle(.init(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1, letterSpacing: 0))
    window.displayIfNeeded()
    view.setSelectedRange(NSRange(location: view.offset(line: 23, column: 2), length: 0))
    view.restoreCursorViewportAnchor(.init(offset: view.offset(line: 9, column: 0), screenY: -3))
    window.displayIfNeeded()
    let oldTop = view.lineRect(at: view.offset(line: 9, column: 0))!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    let changed = externalBase.replacingOccurrences(of: "row 22 한글 😀", with: String(repeating: "수정된 긴 원고 😀 ", count: 35))
    view.applyExternalText(changed, undoable: undoable)
    window.displayIfNeeded()
    let newTop = view.lineRect(at: view.offset(line: 9, column: 0))!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    expect(abs(oldTop - newTop) < 1, "external edit preserves partially visible row 10 (undoable=\(undoable))")
    expect(view.line(at: view.selectedRange().location) == 23, "external edit retains cursor on row 24")
    if undoable {
        view.undoManager?.undo()
        expect(view.string == externalBase, "inline AI edit remains undoable")
    }
}
view.load(externalBase)
view.applyDisplayStyle(.init(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1, letterSpacing: 0))
window.displayIfNeeded()
view.setSelectedRange(NSRange(location: view.offset(line: 23, column: 0), length: 0))
view.restoreCursorViewportAnchor(.init(offset: view.offset(line: 9, column: 0), screenY: 0))
window.displayIfNeeded()
view.applyExternalText("inserted 😀\n" + externalBase)
window.displayIfNeeded()
let movedTop = view.lineRect(at: view.offset(line: 10, column: 0))!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
expect(abs(movedTop) < 1, "insertion above viewport keeps original first visible text at top")
// A toolbar presentation must not reveal the offscreen cursor before toggling Markdown.
view.load((0..<300).map { "row \($0) **bold words** *italic words* " + String(repeating: "wrapped manuscript ", count: 8) }.joined(separator: "\n"))
view.applyDisplayStyle(EditorDisplayStyle(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1.25, letterSpacing: 0))
view.setSelectedRange(NSRange(location: 0, length: 0))
view.scrollCoordinator.restore(.init(offset: view.offset(line: 100, column: 0), screenY: 0))
window.displayIfNeeded()
let toggleAnchor = view.scrollCoordinator.capture(.preserveViewport)!
var formatted = false
view.onToolPresentation = { _ in
    formatted.toggle()
    view.setMarkdownRendering(formatted)
}
for iteration in 0..<12 {
    view.execute(EditorCommand(.tool("display.markdownPreview")))
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    window.displayIfNeeded()
    let y = view.lineRect(at: toggleAnchor.offset)!.minY + view.textContainerOrigin.y - host.contentView.bounds.minY
    expect(abs(y - toggleAnchor.screenY) < 1, "Markdown toggle \(iteration) retains viewport through reflow")
    expect(view.selectedRange().location == 0, "Markdown toggle leaves offscreen cursor unchanged")
}
// Reestablish the pending operation for the detach check below.
events.removeAll()
view.toolBridge.perform(custom) { true }
window.contentView = NSView()
expect(events.last?.phase == .ended && events.last?.outcome == .cancelled, "detaching a tab cancels pending layout completion")
expect(view.textLayoutManager === manager, "all toolbar tools retain TextKit 2")
print("EDITOR TOOL REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-tool-tests-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), '-O', *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
