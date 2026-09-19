#!/usr/bin/env python3
"""Verify top padding and bounce never advance the document window."""
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
final class TopScrollEvent: NSEvent {
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
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
window.orderFront(nil)
func settle(_ seconds: TimeInterval = 0.04) {
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    window.displayIfNeeded()
}
for lineCount in [8, 1000, 100_000] {
    view.loadDocument((0..<lineCount).map { "행 \($0) 한글 원고 abc\n" }.joined())
    let paging = view.windowedDocument!
    host.contentView.setBoundsOrigin(NSPoint(x: host.contentView.bounds.minX, y: 0))
    // This used to return the resident chunk's LAST insertion point at y=0.
    let openingAnchor = view.scrollCoordinator.capture(.preserveViewport)
    precondition(openingAnchor == nil || openingAnchor?.offset == 0,
                 "unlaid top inset must never anchor the chunk tail")
    settle()
    precondition(view.scrollCoordinator.capture(.preserveViewport)?.offset == 0)
    precondition(paging.range.location == 0)
    let originalSelection = view.documentSelection
    let event = TopScrollEvent()
    for _ in 0..<12 {
        event.gesture = .began; event.momentum = []; event.amount = 0
        host.scrollWheel(with: event)
        event.gesture = .changed; event.amount = 120
        host.scrollWheel(with: event)
        precondition(host.contentView.bounds.minY <= 0, "upward bounce jumped downward")
        precondition(view.scrollCoordinator.capture(.preserveViewport)?.offset == 0)
        event.gesture = .ended; event.amount = 0
        host.scrollWheel(with: event)
        event.gesture = []; event.momentum = .changed; event.amount = 70
        host.scrollWheel(with: event)
        settle()
        precondition(paging.range.location == 0 && paging.transitionCount == 0,
                     "top bounce incorrectly loaded the next chunk")
        precondition(view.documentSelection == originalSelection)
    }
    settle(0.7)
    precondition(abs(host.contentView.bounds.minY) < 1, "bounce failed to return to top")
    precondition(view.documentViewportSnapshot()?.firstVisibleLine == 1)
    precondition(!host.hasVerticalScroller && !host.hasHorizontalScroller)
    event.gesture = .began; event.momentum = []; event.amount = 0
    host.scrollWheel(with: event)
    event.gesture = .changed; event.amount = -80
    host.scrollWheel(with: event)
    event.gesture = .ended; event.amount = 0
    host.scrollWheel(with: event)
    settle(0.7)
    let snapshot = view.documentViewportSnapshot()!
    precondition(snapshot.firstVisibleLine > 1 && snapshot.firstVisibleLine < 20,
                 "ordinary downward scrolling stopped working or skipped a chunk")
    print("PASS top padding, repeated bounce/momentum, first row and downward scrolling: \(lineCount) lines")
}
'''

with tempfile.TemporaryDirectory(prefix='textlink-top-scroll-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
