#!/usr/bin/env python3
"""Exercise complete scroll gesture sequences through the native editor host."""
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
sources += [views / 'PreparedManuscript.swift', views / 'EditorToolBridge.swift', views / 'NativeManuscriptView.swift']
prefix = (root / 'tests/editor_binding_regression.py').read_text().split("harness = r'''", 1)[1].split('final class Box', 1)[0]
harness = r'''
setbuf(stdout, nil)
final class ScrollEvent: NSEvent {
    var amount: CGFloat = 0
    var gesture: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    override var type: NSEvent.EventType { .scrollWheel }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var scrollingDeltaY: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { 0 }
    override var deltaY: CGFloat { amount }
    override var deltaX: CGFloat { 0 }
    override var phase: NSEvent.Phase { gesture }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var hasPreciseScrollingDeltas: Bool { true }
}
_ = NSApplication.shared
let view = NativeManuscriptTextView()
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.orderFront(nil)
for lineCount in [1, 8, 20, 50, 1000] {
print("LINES", lineCount)
view.load(String(repeating: "한글 원고 줄입니다.\n", count: lineCount))
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 16, lineHeightMultiple: 1, letterSpacing: 0))
window.displayIfNeeded()
let event = ScrollEvent()
for i in 0..<8 {
    print("BEGIN", i)
    event.gesture = .began; event.amount = 0
    host.scrollWheel(with: event)
    print("OUTWARD", i)
    event.gesture = .changed; event.amount = 120
    host.scrollWheel(with: event)
    window.displayIfNeeded()
    print("END", i)
    event.gesture = .ended; event.amount = 0
    host.scrollWheel(with: event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    print("REVERSE", i)
    let returningY = host.contentView.bounds.minY
    var topProposal = host.contentView.bounds
    topProposal.origin.y = host.contentView.documentRect.minY - topProposal.height - abs(host.contentView.contentInsets.top) - 1
    let top = (host.contentView as! EditorBounceClipView).documentBounds(topProposal).minY
    event.gesture = .began
    host.scrollWheel(with: event)
    if returningY < top - 1 {
        precondition(abs(host.contentView.bounds.minY - returningY) < 1, "new gesture jumps out of the bounce")
    }
    event.gesture = .changed; event.amount = -12
    host.scrollWheel(with: event)
    let inputY = host.contentView.bounds.minY
    window.displayIfNeeded()
    if returningY < top - 1 {
        precondition(abs(inputY - returningY - 12) < 1, "reversal loses the current bounce position")
    }
    event.gesture = .ended; event.amount = 0
    host.scrollWheel(with: event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(host.contentView.bounds.minY.isFinite && view.frame.height.isFinite,
                 "scroll animation produced invalid geometry")
}
let original = view.string
view.insertText("입력", replacementRange: NSRange(location: 0, length: 0))
precondition(view.string == "입력" + original, "editor does not respond after repeated top scrolling")
view.undo(nil)
precondition(view.string == original)
print("PASS repeated top gestures and editing for", lineCount, "lines")
}
print("NATIVE SCROLL REGRESSION COMPLETED")
'''

with tempfile.TemporaryDirectory(prefix='textlink-scroll-test-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
