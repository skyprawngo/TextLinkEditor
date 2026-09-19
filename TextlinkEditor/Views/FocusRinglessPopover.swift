import AppKit
import SwiftUI

/// Scope native focus-ring suppression to this popover without removing keyboard focus.
struct FocusRinglessPopover<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> FocusRinglessHostingView<Content> {
        FocusRinglessHostingView(rootView: content)
    }

    func updateNSView(_ view: FocusRinglessHostingView<Content>, context: Context) {
        view.rootView = content
        view.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusRinglessHostingView<Content>, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

final class FocusRinglessHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        suppressFocusRings(in: self)
    }

    private func suppressFocusRings(in view: NSView) {
        if view.focusRingType != .none { view.focusRingType = .none }
        for child in view.subviews { suppressFocusRings(in: child) }
    }
}
