#!/usr/bin/env python3
"""Exercise the settings scroll bridge in a real SwiftUI Table using temporary fixtures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "TextlinkEditor/Views/Settings/ShortcutsSettingsView.swift").read_text()
start = source.index("private struct ShortcutTableScrollBoundary:")
end = len(source)
helper = source[start:end]
harness = r'''
struct Row: Identifiable { let id: Int }
struct Fixture: View {
    let count: Int
    var body: some View {
        Table((0..<count).map { Row(id: $0) }) {
            TableColumn("Action") { row in
                Text("Action \(row.id)").background(ShortcutTableScrollBoundary())
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(width: 500, height: 300)
    }
}
func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
let host = NSHostingView(rootView: Fixture(count: 80))
window.contentView = host
func settle() {
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    host.layoutSubtreeIfNeeded()
}
settle()
guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
      let scroll = table.enclosingScrollView else { fatalError("No native SwiftUI table") }
precondition(scroll.verticalScrollElasticity == .none, "Boundary helper must reach SwiftUI table scroll view")
let horizontal = scroll.horizontalScrollElasticity
scroll.horizontalScrollElasticity = .allowed
private let probe = descendants(host).compactMap { $0 as? ShortcutTableScrollBoundary.BoundaryView }.first!
probe.configureScrollView()
precondition(scroll.horizontalScrollElasticity == .allowed, "Horizontal behavior must remain unchanged")
scroll.horizontalScrollElasticity = horizontal
precondition(NSScrollView().verticalScrollElasticity == .automatic, "Unrelated scroll views must keep defaults")
let initialHeight = table.frame.height
for y in [CGFloat(0), CGFloat(200), max(0, table.frame.height - scroll.contentSize.height)] {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    settle()
    precondition(scroll.verticalScrollElasticity == .none)
    precondition(abs(table.frame.height - initialHeight) < 1, "Scrolling must not change document height")
}
host.rootView = Fixture(count: 2)
settle()
precondition(scroll.verticalScrollElasticity == .none, "Filtering preserves boundary policy")
host.rootView = Fixture(count: 80)
settle()
precondition(scroll.verticalScrollElasticity == .none, "Restoring rows preserves boundary policy")
print("PASS: real SwiftUI Table attachment, edge/middle positions, stable document height, filtering, horizontal and unrelated scroll isolation")
'''
with tempfile.TemporaryDirectory(prefix="shortcut-scroll-") as directory:
    directory = Path(directory)
    fixture = directory / "main.swift"
    executable = directory / "scroll-regression"
    fixture.write_text("import SwiftUI\nimport AppKit\n" + helper + harness)
    subprocess.run(["swiftc", str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
