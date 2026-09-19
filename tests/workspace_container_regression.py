#!/usr/bin/env python3
"""Exercise panel geometry and identity with the production SwiftUI container."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
sources = sorted((root/'TextlinkEditor/Views/MainEditor/Layout').glob('*.swift'))
sources += [root/'TextlinkEditor/Views/PanelResizeCursorRegion.swift']
harness = r'''
import AppKit
import SwiftUI
enum AppColors { static let separator = Color.gray }
final class State: ObservableObject {
    @Published var width: CGFloat = 500
    @Published var visible = true
}
final class Probe: NSView { static var created = 0; override init(frame: NSRect) { Self.created += 1; super.init(frame: frame) }; required init?(coder: NSCoder) { fatalError() } }
struct ContentProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {}
}
struct Fixture: View {
    @ObservedObject var state: State
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            WorkspaceAIPanel(preferredWidth: $state.width,
                layout: .init(windowWidth: 1000, sidebarWidth: 350, sidebarVisible: true),
                isVisible: state.visible, onResizeEnded: { _ in }) { ContentProbe() }
        }
    }
}
let layout = WorkspacePanelLayout(windowWidth: 1000, sidebarWidth: 350, sidebarVisible: true)
precondition(layout.resolve(600) + 350 + WorkspacePanelLayout.dividerWidth + WorkspacePanelLayout.minimumEditorWidth <= 1000)
precondition(layout.resolve(600) == layout.draggedWidth(from: 600, translation: 0))
precondition(layout.resolve(.nan).isFinite)
let fractional = WorkspacePanelLayout(windowWidth: 1000.75, sidebarWidth: 350, sidebarVisible: true)
precondition(fractional.draggedWidth(from: 600, translation: 0) <= fractional.maximumWidth)
let expanded = WorkspacePanelLayout(windowWidth: 1400, sidebarWidth: 350, sidebarVisible: false)
precondition(expanded.resolve(900) == 600)
_ = NSApplication.shared
let state = State()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
let host = NSHostingView(rootView: Fixture(state: state))
window.contentView = host
window.orderFront(nil)
func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
settle()
precondition(Probe.created == 1)
for _ in 0..<5 { state.visible = false; settle(); state.visible = true; settle() }
precondition(Probe.created == 1, "Visibility changes must retain panel identity")
precondition(state.width == 500, "Temporary constraints must not rewrite persisted width")
print("WORKSPACE CONTAINER REGRESSIONS PASSED")
'''
with tempfile.TemporaryDirectory(prefix='textlink-container-') as directory:
    path=Path(directory)
    (path/'main.swift').write_text(harness)
    subprocess.run(['swiftc', *map(str,sources), str(path/'main.swift'), '-o', str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
