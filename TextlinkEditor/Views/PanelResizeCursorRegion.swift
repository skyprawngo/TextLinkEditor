import SwiftUI
import AppKit

/// AppKit owns cursor entry/exit, without intercepting the SwiftUI divider drag.
struct PanelResizeCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
            addCursorRect(visibleRect, cursor: .columnResize)
        }
    }
}
