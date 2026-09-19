import SwiftUI
import AppKit

struct SidebarRowResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}
    final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            super.resetCursorRects()
            guard !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
            addCursorRect(visibleRect, cursor: .resizeUpDown)
        }
    }
}
