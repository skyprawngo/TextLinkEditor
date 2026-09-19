#!/usr/bin/env python3
"""Exercise actual NSTextView navigation/editing and report large-document layout costs."""
from pathlib import Path
from markdown_test_support import markdown_flags
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
engine = root / 'TextlinkEditor/Services/Editor/TextEngine'
views = root / 'TextlinkEditor/Views/MainEditor/EditorPanel/TextlinkTextView'
markdown_sources = sorted((root / 'TextlinkEditor/Services/Editor/Markdown').glob('*.swift'))
sources = [engine / name for name in ['TextDocument.swift','TextSelection.swift','ViewportManager.swift','EditorState.swift','EditorCommand.swift']]
sources += sorted((engine / 'EditorState').glob('*.swift'))
sources += [root / 'TextlinkEditor/Services/Core/EditorToolRegistry.swift']
sources += markdown_sources
sources += sorted((root / 'TextlinkEditor/Services/Editor/Scroll').glob('*.swift'))
sources += [root / 'TextlinkEditor/Services/FileSystem/Workspace/WorkspaceFileEvents.swift']
sources += [views / 'PreparedManuscript.swift', views / 'EditorToolBridge.swift', views / 'NativeManuscriptView.swift']
prefix = (root / 'tests/editor_binding_regression.py').read_text().split("harness = r'''",1)[1].split('final class Box',1)[0]
harness = r'''
func expect(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); print("PASS \(message)") }
func timed(_ name: String, _ work: () -> Void) { let start = CFAbsoluteTimeGetCurrent(); work(); print("TIME \(name): \((CFAbsoluteTimeGetCurrent() - start) * 1000) ms") }
setbuf(stdout, nil)
let app = NSApplication.shared
let view = NativeManuscriptTextView()
let originalManager = view.textLayoutManager!
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.makeFirstResponder(view)
view.load("alpha beta\n한글 😀 é\nlast")
view.setSelectedRange(NSRange(location: 0, length: 0))
view.moveWordRight(nil)
expect(view.selectedRange().location == 5, "Option Right moves by word")
view.moveWordRightAndModifySelection(nil)
expect((view.string as NSString).substring(with: view.selectedRange()) == " beta", "Option Shift Right extends to next word")
view.moveToEndOfDocumentAndModifySelection(nil)
expect(NSMaxRange(view.selectedRange()) == (view.string as NSString).length, "Command Shift Down extends to document end")
view.moveToBeginningOfDocument(nil)
expect(view.selectedRange().location == 0, "Command Up reaches document start")
view.moveToEndOfLineAndModifySelection(nil)
expect((view.string as NSString).substring(with: view.selectedRange()) == "alpha beta", "Command Shift Right selects current line")
view.moveToEndOfDocument(nil)
view.moveToBeginningOfDocumentAndModifySelection(nil)
expect(view.selectedRange().length == (view.string as NSString).length, "Command Shift Up extends backwards to start")
view.setSelectedRange(NSRange(location: view.offset(line: 1, column: 4), length: 0))
let before = view.selectedRange().location
view.moveLeft(nil)
expect(before - view.selectedRange().location == 2, "native left treats emoji as one character")
view.setSelectedRange(NSRange(location: 0, length: 5))
view.execute(EditorCommand(.format(.bold)))
expect(view.string.hasPrefix("**alpha**"), "formatting uses native editing")
_ = NSApp.sendAction(#selector(NativeManuscriptTextView.undo(_:)), to: view, from: nil)
expect(view.string.hasPrefix("alpha beta"), "native undo restores formatting")
view.execute(EditorCommand(.replace("alpha", replacement: "start", all: true)))
expect(view.string.hasPrefix("start beta"), "replace all retains editor contract")
_ = NSApp.sendAction(#selector(NativeManuscriptTextView.undo(_:)), to: view, from: nil)
expect(view.string.hasPrefix("alpha beta"), "native undo restores replace all")
view.load("한글 입력")
view.setSelectedRange(NSRange(location: 0, length: 0))
view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
expect(view.hasMarkedText(), "native composition keeps marked range")
view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
expect(!view.hasMarkedText() && view.string == "한한글 입력", "composition commits without losing manuscript text")
view.load("😀")
expect(view.lineStarts == [0], "emoji at EOF indexes safely")
view.load("a\r\nb\n")
expect(view.lineStarts == [0,3,5], "CRLF and trailing empty line index")
view.load("abc")
view.isEditable = false
view.replace(NSRange(location: 0, length: 1), with: "x")
expect(view.string == "abc", "read-only prevents command replacement")
view.isEditable = true
view.load("first\nsecond\nthird")
view.setSelectedRange(NSRange(location: 2, length: 0))
let layout = view.textLayoutManager!
let documentRange = layout.textContentManager!.documentRange
layout.ensureLayout(for: documentRange)
let originalY = view.lineRect(at: 6)!.minY
let panel = NSView()
view.installInlinePanel(panel)
layout.ensureLayout(for: documentRange)
let expandedY = view.lineRect(at: 6)!.minY
expect(expandedY - originalY >= 99, "inline panel reserves layout space between manuscript lines")
expect(view.string == "first\nsecond\nthird", "opening inline panel never changes manuscript bytes")
expect(panel.frame.maxY <= expandedY + view.textContainerOrigin.y, "inline panel does not cover next paragraph")
let rulerBoundary = view.convert(host.verticalRulerView!.bounds, from: host.verticalRulerView!).maxX
expect(panel.frame.minX >= rulerBoundary + view.textContainerOrigin.x - 1,
       "inline panel left edge clears actual line-number ruler")

if let path = ProcessInfo.processInfo.environment["TEXTLINK_SNAPSHOT_PATH"] {
    let field = NSTextField(labelWithString: "Inline AI · 수정 지시 입력")
    field.frame = NSRect(x: 12, y: 12, width: 250, height: 24)
    panel.addSubview(field)
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    panel.layer?.borderColor = NSColor.systemBlue.cgColor
    panel.layer?.borderWidth = 1
    panel.layer?.cornerRadius = 12
    window.orderFront(nil)
    window.displayIfNeeded()
    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
view.replace(NSRange(location: 0, length: 0), with: "prefix ")
expect(view.inlinePanel === panel, "editing keeps inline draft panel alive")
view.undo(nil)
expect(view.string == "first\nsecond\nthird", "inline layout preserves native undo")
view.closeInlinePanel()
layout.ensureLayout(for: documentRange)
expect(abs(view.lineRect(at: 6)!.minY - originalY) < 1, "closing inline panel restores paragraph position")
view.load("")
view.installInlinePanel(NSView())
expect(view.string.isEmpty && view.inlinePanel != nil, "inline panel supports empty manuscripts")
view.load("external revision")
expect(view.inlinePanel == nil, "external document replacement removes stale inline anchor")
window.orderFront(nil)
for sample in ["", "first\n", String(repeating: "wrapped 한글 😀 ", count: 100) + "\nnext"] {
    view.load(sample)
    view.setSelectedRange(NSRange(location: (sample as NSString).length, length: 0))
    view.scrollRangeToVisible(view.selectedRange())
    window.displayIfNeeded()
    originalManager.ensureLayout(for: originalManager.textContentManager!.documentRange)
    expect(view.lineRect(at: (sample as NSString).length) != nil, "EOF and empty-line caret has TextKit 2 geometry")
    let endPanel = NSView()
    view.installInlinePanel(endPanel)
    window.displayIfNeeded()
    expect(endPanel.frame.minY >= view.textContainerOrigin.y, "EOF inline panel remains below manuscript")
    expect(view.string == sample, "wrapped and empty paragraphs preserve text")
    view.closeInlinePanel()
}
view.load(String(repeating: "soft wrap word ", count: 70) + "\nsecond\n")
view.scrollRangeToVisible(NSRange(location: 0, length: 0))
window.displayIfNeeded()
let visibleRows = view.visibleManuscriptLines().map { $0.row }
expect(visibleRows == [0, 1, 2], "ruler counts hard lines once including trailing empty line")
view.setSelectedRange(NSRange(location: 1, length: 0))
let resizingPanel = NSView()
view.installInlinePanel(resizingPanel)
let oldWidth = resizingPanel.frame.width
window.setContentSize(NSSize(width: 560, height: 700))
host.layoutSubtreeIfNeeded()
window.displayIfNeeded()
expect(resizingPanel.frame.width < oldWidth, "inline panel follows narrower editor width")
let clipFrame = view.convert(host.contentView.bounds, from: host.contentView)
expect(abs(resizingPanel.frame.maxX - (clipFrame.maxX - view.textContainerOrigin.x)) < 1,
       "inline panel right edge fits actual editor viewport")
let input = NSTextField(frame: NSRect(x: 12, y: 12, width: 180, height: 24))
resizingPanel.addSubview(input)
window.makeFirstResponder(input)
let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "i", charactersIgnoringModifiers: "i",
    isARepeat: false, keyCode: 34)!
let beforeToggle = view.string
expect(view.performKeyEquivalent(with: shortcut), "inline shortcut handles focused input field editor")
expect(view.inlinePanel == nil && window.firstResponder === view, "inline shortcut closes panel and restores manuscript focus")
var opened = 0
let inlineObserver = NotificationCenter.default.addObserver(forName: Notification.Name("editorInlineAI"), object: view, queue: nil) { _ in
    opened += 1
    view.installInlinePanel(resizingPanel)
}
expect(view.performKeyEquivalent(with: shortcut) && opened == 1 && view.inlinePanel != nil,
       "same shortcut reopens inline panel from manuscript")
NotificationCenter.default.removeObserver(inlineObserver)
expect(view.string == beforeToggle, "inline toggling preserves manuscript bytes")

originalManager.ensureLayout(for: originalManager.textContentManager!.documentRange)
expect(resizingPanel.frame.maxY <= view.lineRect(at: view.lineStarts[1])!.minY + view.textContainerOrigin.y,
       "wrapped paragraph and inline panel do not overlap after resizing")
view.closeInlinePanel()
window.setContentSize(NSSize(width: 900, height: 700))
for setting in [CGFloat(12), CGFloat(22)] {
    view.font = NSFont.systemFont(ofSize: setting)
    view.textStorage?.addAttribute(.kern, value: CGFloat(1.5), range: NSRange(location: 0, length: view.textStorage!.length))
    window.displayIfNeeded()
    expect(view.textLayoutManager === originalManager, "font and spacing changes preserve TextKit 2")
}
for count in [1000,10000,100000] {
    let text = String(repeating: "한글 장편 원고입니다. 😀 테스트 문장입니다.\n", count: count)
    let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph, .kern: 0]
    var prepared: PreparedManuscript!
    timed("prepare chunks \(count)") { prepared = try! PreparedManuscript.build(text: text, styleKey: "test", attributes: attributes) }
    timed("load prepared \(count)") { view.load(text, prepared: prepared) }
    timed("display \(count)") { window.displayIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    timed("five viewport jumps \(count)") {
        for fraction in [0.5, 0.9, 0.2, 0.99, 0.0] {
            host.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - host.contentSize.height) * fraction))
            host.reflectScrolledClipView(host.contentView)
            window.displayIfNeeded()
            precondition(!view.visibleManuscriptLines().isEmpty, "scroll rendered no manuscript lines")
            precondition(view.textLayoutManager === originalManager, "scroll entered compatibility mode")
        }
    }
    expect(view.string == text, "prepared chunks preserve whole manuscript")
    expect(view.lineStarts.count == count + 1, "large manuscript line count \(count)")
    timed("first viewport \(count)") { host.layoutSubtreeIfNeeded(); view.textLayoutManager!.ensureLayout(for: NSRect(x: 0,y: 0,width: 800,height: 700)) }
    timed("end navigation \(count)") { view.moveToEndOfDocument(nil); view.scrollRangeToVisible(view.selectedRange()) }
    timed("return to start \(count)") { view.moveToBeginningOfDocument(nil); view.scrollRangeToVisible(view.selectedRange()) }
}
let fullDocument = view.string
view.setSelectedRange(NSRange(location: 16_380, length: 20))
view.replace(view.selectedRange(), with: "한글 😀\n청크 경계")
view.undo(nil)
expect(view.string == fullDocument, "native Undo crosses prepared chunk boundaries")
// Count fragment creation, not just wall time: an accessory query must never
// materialize the unseen remainder of a document. A fresh load avoids warm caches.
final class FragmentCounter: NSObject, NSTextLayoutManagerDelegate {
    let view: NativeManuscriptTextView
    var count = 0
    init(_ view: NativeManuscriptTextView) { self.view = view }
    func textLayoutManager(_ manager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        count += 1
        return view.textLayoutManager(manager, textLayoutFragmentFor: location, in: element)
    }
}
let counter = FragmentCounter(view)
originalManager.delegate = counter
let scrollAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
view.load(fullDocument, prepared: try! PreparedManuscript.build(text: fullDocument, styleKey: "scroll", attributes: scrollAttributes))
view.setSelectedRange(NSRange(location: 0, length: 0))
window.displayIfNeeded()
var frames: [Double] = []
var maxAccessoryFragments = 0
for step in 0..<600 {
    autoreleasepool {
        let beforeFrame = counter.count
        let start = CFAbsoluteTimeGetCurrent()
        host.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 320)))
        host.reflectScrolledClipView(host.contentView)
        window.displayIfNeeded()
        frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        precondition(counter.count - beforeFrame < 1024, "a scroll frame materialized document-sized fragment storage")
        let before = counter.count
        let rows = view.visibleManuscriptLines()
        maxAccessoryFragments = max(maxAccessoryFragments, counter.count - before)
        precondition(counter.count - before <= 2, "ruler materialized offscreen document fragments")
        precondition(!rows.isEmpty && rows.count < 100, "ruler must contain only visible hard lines")
        precondition(zip(rows, rows.dropFirst()).allSatisfy { $0.row < $1.row }, "ruler rows are ordered and unique")
    }
}
frames.sort()
print("TIME continuous 100000 p50 \(frames[300]) ms, p95 \(frames[570]) ms, worst \(frames.last!) ms")
print("MAX accessory fragment creation \(maxAccessoryFragments)")
expect(view.string == fullDocument, "continuous scrolling preserves all manuscript bytes")
for fraction in [0.99, 0.5, 0.1, 0.0] {
    host.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - host.contentSize.height) * fraction))
    host.reflectScrolledClipView(host.contentView)
    window.displayIfNeeded()
    let before = counter.count
    expect(!view.visibleManuscriptLines().isEmpty, "reverse jumps retain visible line numbers")
    precondition(counter.count - before <= 2, "reverse jump ruler traversed outside viewport")
}
originalManager.delegate = view
view.load("match first\nother\nMATCH target\n")
view.execute(EditorCommand(.locate(line: 2, query: "match")))
expect(view.selectedRange().location == 18, "project search selects exact repeated match line")
expect(view.textLayoutManager === originalManager, "all editing, inline UI and scrolling remain TextKit 2")
print("NATIVE EDITOR REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='lore-native-test-') as directory:
    directory = Path(directory)
    main = directory/'main.swift'; main.write_text(prefix + harness)
    executable = directory/'test'
    subprocess.run(['swiftc', *markdown_flags(),'-O',*map(str,sources),str(main),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
