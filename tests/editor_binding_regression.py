#!/usr/bin/env python3
"""Execute the production representable body with a constructible Context shim.

SwiftUI does not expose NSViewRepresentable.Context's initializer. Only conformance
and Context construction are replaced; make/update/coordinator/callback bodies are
read from production unchanged. This is not a SwiftUI scheduling/UI test.
"""
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
sources += [root / 'TextlinkEditor/Services/FileSystem/Workspace/WorkspaceFileEvents.swift', root / 'TextlinkEditor/Services/FileSystem/Workspace/DocumentReconciliation.swift']
sources += [views / 'PreparedManuscript.swift', views / 'EditorToolBridge.swift', *sorted(views.glob('NativeManuscript*.swift'))]
representable = (views / 'TextlinkEditorRepresentable.swift').read_text().split('// MARK: - Preview')[0]
representable = representable.replace('struct TextlinkEditorRepresentable: NSViewRepresentable {', 'struct TextlinkEditorRepresentable {\n    struct Context { let coordinator: Coordinator }')
harness = r'''
import Foundation
import AppKit
import SwiftUI

enum L10n { static func get(_ key: String) -> String { key } }
enum MarkdownFormatType { case bold, italic, boldItalic, strikethrough, underline }
enum AppColors {
    static let nsTextEditorBackground = NSColor.textBackgroundColor
    static let nsEditorText = NSColor.textColor
    static let nsEditorCursor = NSColor.textColor
    static let nsCurrentLineHighlight = NSColor.controlBackgroundColor
}
enum ShortcutAction {
    case moveLineUp, moveLineDown, duplicateLineUp, duplicateLineDown, deleteWordBackward, deleteToLineStart, unrelated, inline
    var rawValue: String { self == .inline ? "ai.inline" : String(describing: self) }
}
final class KeyboardShortcutManager {
    static let shared = KeyboardShortcutManager()
    func action(matching event: NSEvent) -> ShortcutAction? {
        event.keyCode == 34 && event.modifierFlags.intersection([.command, .option, .shift, .control]) == [.command] ? .inline : nil
    }
}
final class TextUndoHistoryManager {
    static let shared = TextUndoHistoryManager()
    enum Area { case editor }
    func setFocusedArea(_ area: Area) {}
}
final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
func binding<T>(_ box: Box<T>) -> Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
func expect(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name); print("PASS \(name)") }
func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
let viewportSuite = "viewport-test-" + UUID().uuidString
let viewportDefaults = UserDefaults(suiteName: viewportSuite)!
let viewportStore = EditorViewportStore(defaults: viewportDefaults)
defer { viewportDefaults.removePersistentDomain(forName: viewportSuite) }
let content = Box("same")
let cursorLine = Box(1)
let cursorColumn = Box(0)
let selected = Box<ClosedRange<Int>?>(nil)
let modified = Box<Set<Int>>([])
let a = UUID(), b = UUID()
let urlA = URL(fileURLWithPath: "/tmp/a.md"), urlB = URL(fileURLWithPath: "/tmp/b.md")
var cache: [URL: String] = [:]
let active = Box<(UUID, URL)>((a, urlA))
let revision = Box(UUID())
func parent(_ id: UUID, _ url: URL, editable: Bool = true, position: (line: Int, column: Int)? = nil) -> TextlinkEditorRepresentable {
    TextlinkEditorRepresentable(text: binding(content), cursorLine: binding(cursorLine), cursorColumn: binding(cursorColumn),
        selectedLineRange: binding(selected), externallyModifiedLines: binding(modified),
        fontSize: 14, fontName: "Menlo", lineHeightMultiple: 1.5, letterSpacing: 0,
        isEditable: editable, initialCursorPosition: position,
        onContentWillChange: { url, value, _, _ in if let url { cache[url] = value } },
        documentID: id, documentURL: url,
        contentRevision: revision.value,
        isDocumentActive: { id, url, expectedRevision in active.value.0 == id && active.value.1 == url && revision.value == expectedRevision }, viewportStore: viewportStore)
}
var p = parent(a, urlA)
let coordinator = p.makeCoordinator()
let context = TextlinkEditorRepresentable.Context(coordinator: coordinator)
let view = p.makeNSView(context: context)
drain()
view.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
expect(cache[urlA] == view.textView.string, "typing updates owner cache synchronously")
drain()
p.updateNSView(view, context: context)
expect(view.textView.manuscriptUndoManager.canUndo, "A records undo")
let aText = content.value
content.value = aText
active.value = (b, urlB)
p = parent(b, urlB)
p.updateNSView(view, context: context)
drain()
expect(!view.textView.manuscriptUndoManager.canUndo, "same text B has independent undo")
active.value = (a, urlA)
p = parent(a, urlA)
p.updateNSView(view, context: context)
drain()
expect(view.textView.manuscriptUndoManager.canUndo, "A undo retained after B")
view.textView.manuscriptUndoManager.undo()
expect(view.textView.string == "same", "A undo restores own text")
content.value = view.textView.string
let renamed = URL(fileURLWithPath: "/tmp/renamed.md")
active.value = (a, renamed)
p = parent(a, renamed)
p.updateNSView(view, context: context)
expect(view.textView.manuscriptUndoManager.canRedo, "same UUID rename preserves redo")
view.textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil)
expect(cache[renamed] == view.textView.string && content.value.contains("한"), "flush owns renamed document")
drain()
p.updateNSView(view, context: context)

// Model the scheduling gap between the parent loading B and updateNSView observing B.
view.textView.insertText("queued-A", replacementRange: NSRange(location: NSNotFound, length: 0))
active.value = (b, urlB)
content.value = "B disk content"
let next = parent(b, urlB)
var obsolete = parent(a, renamed)
obsolete.editCommand = EditorCommand(.replace("queued-A", replacement: "WRONG", all: true))
obsolete.updateNSView(view, context: context)
expect(view.textView.string.contains("queued-A"), "obsolete presentation cannot consume editor command")
drain()
expect(content.value == "B disk content", "pending A callback cannot replace B binding")
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil)
expect(content.value == "B disk content", "old document flush cannot replace B binding")
expect(cache[renamed]?.contains("queued-A") == true, "old document flush still preserves A cache")
next.updateNSView(view, context: context)
drain()
view.textView.insertText("queued-B", replacementRange: NSRange(location: NSNotFound, length: 0))
revision.value = UUID()
content.value = "B external revision"
drain()
expect(content.value == "B external revision", "queued same-document callback cannot replace external revision")
let reloaded = parent(b, urlB)
reloaded.updateNSView(view, context: context)
expect(view.textView.string == "B external revision", "external revision clears pending buffer")
expect(!view.textView.manuscriptUndoManager.canUndo, "external revision invalidates obsolete undo")
// A failed read presents a disabled empty state but must never become a saved draft.
var invalid = parent(b, urlB)
invalid = TextlinkEditorRepresentable(text: binding(content), cursorLine: binding(cursorLine), cursorColumn: binding(cursorColumn),
    selectedLineRange: binding(selected), externallyModifiedLines: binding(modified),
    fontSize: 14, fontName: "Menlo", lineHeightMultiple: 1.5, letterSpacing: 0,
    isEditable: false, initialCursorPosition: nil,
    onContentWillChange: { url, value, _, _ in if let url { cache[url] = value } },
    documentID: b, documentURL: urlB, contentRevision: revision.value,
    isDocumentActive: { id, url, expectedRevision in active.value.0 == id && active.value.1 == url && revision.value == expectedRevision }, viewportStore: viewportStore)
invalid.updateNSView(view, context: context)
cache[urlB] = "preserved read baseline"
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil)
expect(cache[urlB] == "preserved read baseline", "read-failure flush cannot overwrite cache")
active.value = (a, urlA)
content.value = "same"
parent(a, urlA).updateNSView(view, context: context)
expect(cache[urlB] == "preserved read baseline", "leaving read-failure document cannot overwrite cache")
view.textView.setSelectedRange(NSRange(location: 0, length: 2))
drain()
expect(selected.value == 1...1, "native selection publishes status range")
var captured: String?
let capture: (String, NSRange) -> Void = { text, range in captured = (text as NSString).substring(with: range) }
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil, userInfo: ["captureSelection": capture])
expect(captured == "sa", "AI capture preserves selected manuscript range")
let original = view.textView.string
let apply: (String, NSRange) -> String? = { text, _ in text == original ? "AI proposal" : nil }
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil, userInfo: ["applyRevision": apply])
expect(view.textView.string == "AI proposal" && cache[urlA] == "AI proposal", "AI apply updates actual native editor and owner cache")
view.textView.undo(nil)
expect(view.textView.string == original, "AI application is native Undo operation")
var staleInvoked = false
let staleCapture: (String, NSRange) -> Void = { _, _ in staleInvoked = true }
active.value = (b, urlB)
NotificationCenter.default.post(name: Notification.Name("editorWillPerformFileOperation"), object: nil, userInfo: ["captureSelection": staleCapture])
expect(!staleInvoked, "inactive presentation cannot capture another manuscript")
active.value = (b, urlB)
content.value = ""
let loading = parent(b, urlB, editable: false)
loading.updateNSView(view, context: context)
revision.value = UUID()
content.value = "first\nsecond\nlast"
let loaded = parent(b, urlB, position: (line: 2, column: 2))
loaded.updateNSView(view, context: context)
drain()
expect(view.textView.selectedRange().location == 15, "asynchronous loading restores remembered cursor")
expect(cursorLine.value == 3 && cursorColumn.value == 2, "loaded cursor publishes native position")
expect(view.textView.textLayoutManager != nil, "tab switching and AI edits retain TextKit 2")

// Count actual NSTextView snapshots: geometry-only updates must not read the
// complete document. The temporary test source only removes `final` to observe it.
final class SnapshotCountingView: NativeManuscriptTextView {
    var snapshotReads = 0
    override var string: String {
        get { snapshotReads += 1; return super.string }
        set { super.string = newValue }
    }
}
let counting = SnapshotCountingView()
content.value = String(repeating: "한글 장편 😀 폭 변경 검증 문장입니다.\n", count: 100000)
counting.load(content.value)
view.textView.delegate = nil
view.documentView = counting
counting.delegate = coordinator
coordinator.editors[b] = counting
parent(b, urlB).updateNSView(view, context: context)
drain()
counting.snapshotReads = 0
for _ in 0..<100 { parent(b, urlB).updateNSView(view, context: context) }
expect(counting.snapshotReads == 0, "100 geometry-only updates take no whole-document snapshots")
content.value = "external replacement without a new revision"
parent(b, urlB).updateNSView(view, context: context)
expect(counting.string == content.value, "changed binding without revision still replaces native text")
counting.insertText("native ", replacementRange: NSRange(location: 0, length: 0))
drain()
parent(b, urlB).updateNSView(view, context: context)
expect(counting.string == content.value && counting.manuscriptUndoManager.canUndo, "native publication retains text and undo with snapshot guard")
var presentationCount = 0
var updatingView = false
var toggle = parent(b, urlB)
toggle.onToolPresentation = { _ in
    expect(!updatingView, "presentation callback runs outside view update")
    presentationCount += 1
}
toggle.editCommand = EditorCommand(.tool("display.markdownPreview"))
updatingView = true
toggle.updateNSView(view, context: context)
toggle.updateNSView(view, context: context)
updatingView = false
expect(presentationCount == 0, "view update defers state-changing tool callback")
drain()
expect(presentationCount == 1, "repeated view updates execute the command only once")
toggle.editCommand = EditorCommand(.tool("display.markdownPreview"))
toggle.updateNSView(view, context: context)
active.value = (a, urlA)
drain()
expect(presentationCount == 1, "queued tool cannot run after active document changes")
let live = NativeManuscriptTextView()
let rawMarkdown = "**bold**\n*italic*\n~~strike~~\n<u>under</u>\nplain"
live.load(rawMarkdown)
live.applyDisplayStyle(EditorDisplayStyle(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1.25, letterSpacing: 0))
live.setSelectedRange(NSRange(location: (rawMarkdown as NSString).length, length: 0))
live.setMarkdownRendering(true)
expect(live.isEditable && live.string == rawMarkdown && live.lineStarts.count == 5, "formatted mode keeps editable source and line numbers")
let boldFont = live.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "formatted editor applies bold")
live.isEditable = true
live.isSelectable = true
live.refreshMarkdownRendering()
let updatedBold = live.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
expect(NSFontManager.shared.traits(of: updatedBold).contains(.boldFontMask), "view configuration must retain formatted bold")
let spacing = live.textStorage!.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as! NSParagraphStyle
expect(spacing.lineHeightMultiple == 1.25, "formatted mode uses the same editor line spacing")
expect(!live.manuscriptUndoManager.canUndo, "display toggle does not add undo entries")
live.insertText("NEW", replacementRange: NSRange(location: 2, length: 4))
expect(live.string.hasPrefix("**NEW**"), "editing formatted content preserves Markdown delimiters")
live.manuscriptUndoManager.undo()
expect(live.string == rawMarkdown, "formatted edit supports native undo")
live.setMarkdownRendering(false)
let markerFont = live.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
expect(markerFont.pointSize == 14 && live.string == rawMarkdown, "source mode restores visible syntax without rewriting text")
let headings = "# 제목 **굵게**\n## 소제목\n본문 **강조**\n끝"
live.load(headings)
// Match the representable's first-update order: mode arrives before display style.
live.setMarkdownRendering(true)
live.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
live.refreshMarkdownRendering()
func markdownFont(_ word: String) -> NSFont {
    live.textStorage!.attribute(.font, at: (live.string as NSString).range(of: word).location, effectiveRange: nil) as! NSFont
}
expect(markdownFont("제목").pointSize > markdownFont("소제목").pointSize && markdownFont("소제목").pointSize > 16,
       "ATX heading levels render with distinct sizes")
expect(NSFontManager.shared.traits(of: markdownFont("강조")).contains(.boldFontMask), "Korean body bold renders with system font")
expect(markdownFont("굵게").pointSize == markdownFont("제목").pointSize, "inline bold retains heading size")
live.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 20, lineHeightMultiple: 1.4, letterSpacing: 1))
expect(markdownFont("제목").pointSize == 36, "font changes invalidate heading styling")
live.setMarkdownRendering(false)
expect(markdownFont("제목").pointSize == 20 && live.string == headings, "source toggle restores body font without modifying source")
live.setMarkdownRendering(true)
expect(markdownFont("제목").pointSize == 36, "repeated toggle restores heading style")
let codeSource = "~~~md\n# 코드 **literal**\n~~~\n\\# escaped\n####### invalid\n# 실제"
live.load(codeSource)
live.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
live.refreshMarkdownRendering()
expect(markdownFont("코드").pointSize == 16 && markdownFont("literal").pointSize == 16,
       "fenced heading and emphasis remain literal")
expect(markdownFont("escaped").pointSize == 16 && markdownFont("invalid").pointSize == 16,
       "escaped and invalid heading markers remain source")
expect(markdownFont("실제").pointSize > 16, "heading resumes after code fence")
live.load("[링크](https://example.com) `code` *기울임*\n끝")
live.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
live.refreshMarkdownRendering()
expect(live.textStorage!.attribute(.link, at: 1, effectiveRange: nil) != nil, "formatted mode activates safe links")
live.setMarkdownRendering(false)
for key in MarkdownSourceStyling.ownedKeys {
    var found = false
    live.textStorage!.enumerateAttribute(key, in: NSRange(location: 0, length: live.textStorage!.length)) { value, _, _ in
        if value != nil { found = true }
    }
    expect(!found, "source mode clears all parser-owned presentation attributes")
}
// Persist a viewport independently of the cursor and recreate the entire native view.
_ = NSApplication.shared
// Tab installation must fit the clip view after rulers/scrollers are tiled.
let widthWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
widthWindow.isReleasedWhenClosed = false
active.value = (a, urlA)
content.value = String(repeating: "줄바꿈 폭을 확인하는 긴 원고 문장입니다. ", count: 100)
let widthParent = parent(a, urlA)
let widthCoordinator = widthParent.makeCoordinator()
let widthContext = TextlinkEditorRepresentable.Context(coordinator: widthCoordinator)
let widthHost = widthParent.makeNSView(context: widthContext)
widthWindow.contentView = widthHost
widthWindow.orderFront(nil)
for style: NSScroller.Style in [.overlay, .legacy] {
    widthHost.scrollerStyle = style
    for width: CGFloat in [650, 420, 850] {
        widthWindow.setContentSize(NSSize(width: width, height: 400))
        for id in [b, a, b, a] {
            let url = id == a ? urlA : urlB
            active.value = (id, url)
            parent(id, url).updateNSView(widthHost, context: widthContext)
            let clip = widthHost.contentView
            let availableWidth = clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
            expect(abs(widthHost.textView.frame.width - availableWidth) < 1,
                "tab installation fits before deferred layout and viewport restoration")
            widthWindow.displayIfNeeded()
            drain()
            expect(abs(widthHost.textView.frame.width - availableWidth) < 1,
                "new and cached tabs fit the actual clip width with rulers and scrollers")
            let left = NSRect(x: -10000, y: clip.bounds.minY, width: clip.bounds.width, height: clip.bounds.height)
            let right = NSRect(x: 10000, y: clip.bounds.minY, width: clip.bounds.width, height: clip.bounds.height)
            expect(abs(clip.constrainBoundsRect(left).minX - clip.constrainBoundsRect(right).minX) < 1,
                "tab switch leaves no horizontal scroll range")
        }
    }
}
TextlinkEditorRepresentable.dismantleNSView(widthHost, coordinator: widthCoordinator)
widthWindow.close()
active.value = (b, urlB)
content.value = (1...200).map { "row \($0) 한글" }.joined(separator: "\n")
let savedViewport = EditorViewportPosition(firstVisibleLine: 80, firstLineText: "row 80 한글", offsetWithinLine: 0)
viewportStore.save(savedViewport, for: urlB)
let reloadedStore = EditorViewportStore(defaults: viewportDefaults)
expect(reloadedStore.position(for: urlB) == savedViewport, "viewport line and text survive store recreation")
var resume = parent(b, urlB, position: (0, 0))
resume.viewportStore = reloadedStore
let resumeCoordinator = resume.makeCoordinator()
let resumeContext = TextlinkEditorRepresentable.Context(coordinator: resumeCoordinator)
let resumeHost = resume.makeNSView(context: resumeContext)
let resumeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
resumeWindow.isReleasedWhenClosed = false
resumeWindow.contentView = resumeHost
resumeWindow.orderFront(nil)
for _ in 0..<10 { drain() }
resumeHost.layoutSubtreeIfNeeded()
resumeCoordinator.saveViewport()
let restoredViewport = reloadedStore.position(for: urlB)!
expect(resumeHost.textView.visibleManuscriptLines().first?.row == 79, "actual viewport begins at saved line")
expect(restoredViewport.firstVisibleLine == 80 && restoredViewport.firstLineText == "row 80 한글",
    "native reopening restores first visible line instead of offscreen cursor")
expect(resumeHost.textView.selectedRange().location == 0, "viewport restoration does not move the cursor")
resumeHost.textView.restoreCursorViewportAnchor(.init(offset: resumeHost.textView.lineStarts[119], screenY: 0))
drain()
TextlinkEditorRepresentable.dismantleNSView(resumeHost, coordinator: resumeCoordinator)
expect(reloadedStore.position(for: urlB)?.firstVisibleLine == 120, "closing saves latest scroll synchronously")
resumeWindow.close()
let moveEvents = WorkspaceFileEvents()
let movedStore = EditorViewportStore(defaults: viewportDefaults, events: moveEvents)
let movedURL = URL(fileURLWithPath: "/tmp/viewport-renamed.md")
moveEvents.publish(WorkspaceFileEvent(url: movedURL, change: .moved(from: urlB)))
expect(movedStore.position(for: movedURL)?.firstVisibleLine == 120 && movedStore.position(for: urlB) == nil,
    "file rename carries its saved viewport")
var rows = (1...200).map { "unique row \($0)" }
rows[99] = "A"; rows[129] = "B"
rows.insert(contentsOf: (1...20).map { "added \($0)" }, at: 29)
let anchor = EditorViewportPosition(firstVisibleLine: 100, firstLineText: "A", offsetWithinLine: 0,
    cursorLine: 130, cursorLineText: "B", cursorOffsetWithinLine: 1)
func resolve(_ value: EditorViewportPosition, _ lines: [String]) -> EditorViewportResolver.Resolution {
    EditorViewportResolver.resolve(value, lineCount: lines.count) { lines[$0] }
}
expect(resolve(anchor, rows).firstRow == 119, "insertion at row 30 moves A 100 to 120")
expect(resolve(anchor, rows).cursorRow == 149, "cursor B moves 130 to 150")
var missingFirst = rows; missingFirst[119] = "edited A"
expect(resolve(anchor, missingFirst).firstRow == 119, "missing first text falls back to cursor distance")
var duplicateFirst = rows; duplicateFirst[99] = "A"
expect(resolve(anchor, duplicateFirst).firstRow == 119, "cursor disambiguates duplicated first-line text")
var betweenAnchors = rows; betweenAnchors.insert(contentsOf: ["between", "between2"], at: 125)
expect(resolve(anchor, betweenAnchors).firstRow == 119, "unique first text takes precedence over cursor displacement")
var contextAnchor = anchor
contextAnchor.cursorTextBefore = "B"; contextAnchor.cursorTextAfter = ""
var changedCursor = missingFirst; changedCursor[149] = "prefix B suffix"
expect(resolve(contextAnchor, changedCursor).firstRow == 119, "cursor context survives edits elsewhere on cursor line")
expect(resolve(contextAnchor, changedCursor).cursorColumn == 8, "cursor context restores the character boundary")
let legacyData = Data(#"{"firstVisibleLine":2,"firstLineText":"old","offsetWithinLine":0}"#.utf8)
let legacy = try! JSONDecoder().decode(EditorViewportPosition.self, from: legacyData)
expect(legacy.cursorLine == nil && resolve(legacy, ["new", "old"]).firstRow == 1, "legacy records remain readable")
expect(resolve(anchor, ["short"]).firstRow == 0, "truncated document clamps safely")
let corruptDefaults = UserDefaults(suiteName: viewportSuite + "-corrupt")!
defer { corruptDefaults.removePersistentDomain(forName: viewportSuite + "-corrupt") }
let corruptBytes = Data("invalid".utf8)
corruptDefaults.set(corruptBytes, forKey: "editor.viewportPositions.v1")
let corruptStore = EditorViewportStore(defaults: corruptDefaults)
corruptStore.save(anchor, for: urlB)
expect(corruptDefaults.data(forKey: "editor.viewportPositions.v1") == corruptBytes, "unreadable location records are preserved")

// Reproduce the user's example with a newly created native editor and real layout.
content.value = rows.joined(separator: "\n")
reloadedStore.save(anchor, for: urlB)
var shifted = parent(b, urlB, position: (0, 0))
shifted.viewportStore = reloadedStore
let shiftedCoordinator = shifted.makeCoordinator()
let shiftedHost = shifted.makeNSView(context: .init(coordinator: shiftedCoordinator))
let shiftedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
shiftedWindow.isReleasedWhenClosed = false
shiftedWindow.contentView = shiftedHost
shiftedWindow.orderFront(nil)
for _ in 0..<10 { drain() }
expect(shiftedHost.textView.visibleManuscriptLines().first?.row == 119, "reopened native viewport starts at shifted A line 120")
expect(shiftedHost.textView.position(at: shiftedHost.textView.selectedRange().location).line == 149,
    "reopened native cursor follows B to line 150 without scrolling to it")
shiftedCoordinator.saveViewport()
expect(reloadedStore.position(for: urlB)?.cursorTextBefore == "B", "cursor-adjacent text is persisted")
TextlinkEditorRepresentable.dismantleNSView(shiftedHost, coordinator: shiftedCoordinator)
shiftedWindow.close()

let concurrentView = NativeManuscriptTextView()
concurrentView.isEditable = true
let concurrentBase = "첫째\n둘째\n셋째"
let concurrentHuman = "사람이 추가\n첫째\n둘째\n셋째"
concurrentView.loadDocument(concurrentHuman)
let concurrentMerged = try! ManuscriptTextMerge.merge(base: concurrentBase, current: concurrentView.documentText, proposed: "첫째\nAI 교체\n셋째")
concurrentView.applyExternalText(concurrentMerged, undoable: true)
expect(concurrentView.documentText == "사람이 추가\n첫째\nAI 교체\n셋째", "native AI patch retains typing before shifted target")
concurrentView.manuscriptUndoManager.undo()
expect(concurrentView.documentText == concurrentHuman, "native Undo removes only merged AI edit")
print("EDITOR BINDING REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='lore-binding-tests-') as directory:
    directory = Path(directory)
    adapter = directory / 'Representable.swift'
    adapter.write_text(representable)
    observable_native = directory / 'NativeManuscriptView.swift'
    observable_native.write_text((views / 'NativeManuscriptView.swift').read_text().replace(
        'final class NativeManuscriptTextView:', 'class NativeManuscriptTextView:', 1))
    sources = [observable_native if path.name == 'NativeManuscriptView.swift' else path for path in sources]
    main = directory / 'main.swift'
    main.write_text(harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), *map(str, sources), str(adapter), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
