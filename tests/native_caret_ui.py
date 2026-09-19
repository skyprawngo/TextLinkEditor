#!/usr/bin/env python3
"""Build, then open this fixture and click/scroll/toggle. Actual caret results go to /tmp/textlink-caret-validation.log; inactive/headless windows cannot pass."""
from pathlib import Path
import subprocess, plistlib
root=Path(__file__).resolve().parents[1]
ns={'__file__':str(root/'tests/native_cursor_regression.py')}
import sys
sys.path.insert(0,str(root/'tests'))
s=(root/'tests/native_cursor_regression.py').read_text()
exec(s[:s.index("\nharness = r'''")],ns)
import argparse
parser=argparse.ArgumentParser(description='Build an isolated app to verify the actual blinking caret after clicks, scrolls and Markdown toggles.')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--windowed', action='store_true', help='Exercise the production chunk window with a large manuscript.')
args=parser.parse_args()
app=args.output; binary=app/'Contents/MacOS/TextlinkCaretValidation'; binary.parent.mkdir(parents=True,exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.textlink.caret.validation','CFBundleName':'TextlinkCaretValidation','CFBundleExecutable':'TextlinkCaretValidation','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
harness=r'''
freopen("/tmp/textlink-caret-validation.log", "w", stdout)
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let view = NativeManuscriptTextView()
let host = NativeManuscriptHost(textView: view)
let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 850, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Textlink caret validation"
let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 650))
host.frame = NSRect(x: 0, y: 0, width: 850, height: 610)
host.autoresizingMask = [.width, .height]
rootView.addSubview(host)
final class Actions: NSObject, NSTextViewDelegate {
    var enabled = true
    @objc func toggle() { enabled.toggle(); view.setMarkdownRendering(enabled) }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard view.windowedDocument?.installing != true else { return }
        view.refreshMarkdownRendering()
        print("SELECTION", view.selectedRange())
    }
}
let actions = Actions()
view.delegate = actions
let button = NSButton(title: "Toggle Markdown", target: actions, action: #selector(Actions.toggle))
button.frame = NSRect(x: 16, y: 616, width: 180, height: 28)
button.autoresizingMask = [.minYMargin]
rootView.addSubview(button)
window.contentView = rootView
view.load((1...6).map { index in "## **제목 \(index). 문장과 판단**\n\n" + String(repeating: "화자는 무엇을 보았는지만 전달하지 않는다. 본 것을 즉시 분류하고 좋고 나쁨을 매긴다. ", count: 3) + "\n\n- **관찰:** 눈에 들어온 것\n- **해석:** 이유와 판단\n\n" }.joined())
view.applyDisplayStyle(EditorDisplayStyle(fontName: "SF Pro", fontSize: 18, lineHeightMultiple: 1.2, letterSpacing: 0))
view.setMarkdownRendering(true)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
NSApp.activate(ignoringOtherApps: true)
func indicators(in node: NSView) -> [NSTextInsertionIndicator] {
    (node as? NSTextInsertionIndicator).map { [$0] } ?? node.subviews.flatMap { indicators(in: $0) }
}
var lastState = ""
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    guard window.isKeyWindow, view.selectedRange().length == 0,
          let indicator = indicators(in: view).first(where: { !$0.isHidden }),
          let manager = view.textLayoutManager, let location = view.textLocation(at: view.selectedRange().location) else { return }
    // Read the actual drawn indicator BEFORE any geometry query. Do not force layout.
    let actual = view.convert(indicator.bounds, from: indicator)
    var expected: NSRect?
    manager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
        expected = rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        return false
    }
    guard let expected, expected.intersects(view.visibleRect) else { return }
    let state = "\(view.selectedRange())|\(actual)|\(expected)|\(host.contentView.bounds.origin)"
    guard state != lastState else { return }
    lastState = state
    let matches = abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1 && abs(actual.height - expected.height) < 1
    print(matches ? "PASS visible caret" : "FAIL visible caret", state)
}
app.run()
'''
if args.windowed:
    harness = harness.replace('view.load(', 'view.loadDocument(').replace('(1...6)', '(1...2000)')
    harness = harness.replace('print("SELECTION", view.selectedRange())', 'print("SELECTION", view.documentSelection, "WINDOW", view.windowedDocument?.range as Any)')
main2=app/'Contents/MacOS/main.swift';main2.write_text(ns['prefix']+harness)
subprocess.run(['swiftc',*ns['markdown_flags'](),*map(str,ns['sources']),str(main2),'-o',str(binary)],check=True)
print(app)
