#!/usr/bin/env python3
"""Exercise live AppKit width changes at multiple positions in a 100,000-line fixture."""
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
func expect(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name); print("PASS \(name)") }
let app = NSApplication.shared
let view = NativeManuscriptTextView()
let manager = view.textLayoutManager!
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = host
window.makeFirstResponder(view)
window.orderFront(nil)
let text = String(repeating: "한글 장편 원고입니다. 😀 테스트 문장입니다. 폭을 변경할 때 즉시 줄바꿈이 이루어져야 합니다. 긴 문장과 짧은 문장이 함께 있습니다.\n", count: 100000)
view.load(text, prepared: try! PreparedManuscript.build(text: text, styleKey: "resize", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
window.displayIfNeeded()
let bounce = EditorScrollMotion(scroll: host)
host.contentView.scroll(to: .zero)
_ = bounce.handle(delta: -100, phase: .changed, momentum: [])
_ = bounce.handle(delta: 0, phase: .ended, momentum: [])
bounce.advanceReturn(by: 0.02)
window.displayIfNeeded()
let returningY = host.contentView.bounds.minY
expect(returningY < 0, "native manuscript preserves the stretched viewport during layout")
_ = bounce.handle(delta: 0, phase: .began, momentum: [])
_ = bounce.handle(delta: 4, phase: .changed, momentum: [])
window.displayIfNeeded()
expect(abs(host.contentView.bounds.minY - returningY - 4) < 1,
       "native manuscript reverses from the current bounce position without a boundary jump")
bounce.cancel()
host.contentView.scroll(to: .zero)
for fraction in [0.0, 0.5, 0.9] {
    view.setSelectedRange(NSRange(location: Int(Double((text as NSString).length) * fraction), length: 0))
    view.scrollRangeToVisible(view.selectedRange())
    window.displayIfNeeded()
    let selection = view.selectedRange()
    var times: [Double] = []
    var firstRow: Int?
    for step in 0..<100 {
        autoreleasepool {
            let start = CFAbsoluteTimeGetCurrent()
            window.setContentSize(NSSize(width: 900 - abs(50 - step) * 10, height: 700))
            window.displayIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let rows = view.visibleManuscriptLines()
            precondition(!rows.isEmpty, "resizing left the ruler/viewport blank")
            if let firstRow {
                precondition(abs(rows[0].row - firstRow) <= 1, "width changes lost the visible paragraph anchor")
            } else { firstRow = rows[0].row }
            precondition(view.selectedRange() == selection, "resize changed the selection")
            let clip = host.contentView
            let availableWidth = clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
            precondition(abs(view.frame.width - availableWidth) < 1,
                         "resizing must exclude ruler and scroller insets from wrapping width")
            precondition(abs(view.textContainer!.size.width - view.frame.width + 2 * view.textContainerInset.width) < 1,
                         "text container width was deferred instead of tracking the view")
        }
    }
    times.sort()
    print("RESIZE \(fraction): p50 \(times[50]) ms, p95 \(times[95]) ms, max \(times.last!) ms")
}
expect(view.string == text, "continuous width changes preserve all 100000 lines")
expect(view.textLayoutManager === manager, "width changes retain TextKit 2")
view.setSelectedRange(NSRange(location: 0, length: 0))
view.scrollRangeToVisible(view.selectedRange())
view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
window.setContentSize(NSSize(width: 540, height: 700))
window.displayIfNeeded()
expect(view.hasMarkedText(), "resize preserves ongoing Korean composition")
view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
expect(view.string == "한" + text, "composition commits after resize")
view.undo(nil)
expect(view.string == text, "native Undo restores text after resize and composition")
for source in ["마지막 글씨", "첫 줄\n둘째 줄\n마지막 글씨", "첫 줄\n마지막 글씨\n",
               String(repeating: "긴 원고 줄\n", count: 100) + "마지막 글씨"] {
    let view = NativeManuscriptTextView()
    let host = NativeManuscriptHost(textView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeFirstResponder(view)
    window.orderFront(nil)
    view.load(source)
    view.applyDisplayStyle(EditorDisplayStyle(fontName: "Menlo", fontSize: 14, lineHeightMultiple: 1.5, letterSpacing: 0))
    for height: CGFloat in [400, 750, 300] {
        window.setContentSize(NSSize(width: 540, height: height))
        let end = (source as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        window.displayIfNeeded()
        let targetY = view.lineRect(at: end)!.minY + view.textContainerOrigin.y
        var proposed = host.contentView.bounds
        proposed.origin.y = view.frame.maxY + height
        expect(abs(host.contentView.constrainBoundsRect(proposed).minY - targetY) < 1,
               "maximum scroll position leaves the final line at viewport top")
        view.scrollCoordinator.restore(.init(offset: end, screenY: 0))
        window.displayIfNeeded()
        let lastLine = view.lineRect(at: end)!
        expect(abs(lastLine.minY + view.textContainerOrigin.y - host.contentView.bounds.minY) < 1,
               "last line can reach viewport top at every window height")
        expect(view.string == source, "scroll space adds no manuscript characters")
        view.insertText("끝", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(view.string == source + "끝", "last line remains editable at viewport top")
        view.undo(nil)
        expect(view.string == source, "Undo preserves document after editing above scroll space")
    }
    window.close()
}
print("NATIVE RESIZE REGRESSION COMPLETED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-resize-test-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text(prefix + harness)
    executable = directory / 'test'
    subprocess.run(['swiftc', *markdown_flags(), '-O', *map(str, sources), str(main), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
