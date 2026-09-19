import AppKit

@main struct BounceRegression {
    static func main() {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.contentView = EditorBounceClipView(frame: scroll.contentView.frame)
        final class Document: NSView { override var isFlipped: Bool { true } }
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 600, height: 5000))
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 400, right: 0)
        scroll.tile()
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = -10000
        let top = clip.constrainBoundsRect(bounds).minY
        func place(_ y: CGFloat) { clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y)) }
        let bounce = EditorScrollMotion(scroll: scroll)
        place(top)
        precondition(bounce.handle(delta: -80, phase: .changed, momentum: []))
        let stretched = clip.bounds.minY
        precondition(stretched < top && stretched > top - 80, "outward scrolling remains elastic")
        _ = bounce.handle(delta: 0, phase: .ended, momentum: [])
        bounce.advanceReturn(by: 0.02)
        let returning = clip.bounds.minY
        precondition(returning > stretched && returning < top, "release animates instead of snapping")
        _ = bounce.handle(delta: 0, phase: .began, momentum: [])
        precondition(clip.bounds.minY == returning, "new gesture must not reset the spring position")
        _ = bounce.handle(delta: 3, phase: .changed, momentum: [])
        precondition(abs(clip.bounds.minY - returning - 3) < 0.001, "reverse input moves immediately from the displayed position")
        let interrupted = clip.bounds.minY
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(clip.bounds.minY == interrupted, "cancelled spring must not overwrite new input")
        _ = bounce.handle(delta: 60, phase: .changed, momentum: [])
        precondition(abs(clip.bounds.minY - interrupted - 60) < 0.001, "crossing the boundary consumes only the actual delta")
        let insideY = clip.bounds.minY
        precondition(bounce.handle(delta: 3, phase: .changed, momentum: []))
        precondition(clip.bounds.minY == insideY + 3, "the same controller continues inside the document")
        place(top + 5)
        precondition(bounce.handle(delta: -40, phase: [], momentum: .changed))
        precondition(clip.bounds.minY < top, "momentum reaching the edge also stretches")
        let momentumStretch = clip.bounds.minY
        _ = bounce.handle(delta: -100, phase: [], momentum: .changed)
        precondition(clip.bounds.minY == momentumStretch, "old momentum cannot fight the spring")
        for _ in 0..<120 { bounce.advanceReturn(by: 1.0 / 120) }
        precondition(clip.bounds.minY == top, "return settles at the inset-aware boundary")
        place(top)
        _ = bounce.handle(delta: -20, phase: [], momentum: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(abs(clip.bounds.minY - top) < 0.1, "phase-less mouse wheels do not leave a stuck stretch")
        bounce.cancel()
        var bottomProposal = clip.bounds
        bottomProposal.origin.y = 10000
        let bottom = (clip as! EditorBounceClipView).documentBounds(bottomProposal).minY
        place(bottom)
        _ = bounce.handle(delta: 80, phase: .changed, momentum: [])
        precondition(clip.bounds.minY > bottom, "bottom bounce is retained")
        _ = bounce.handle(delta: 0, phase: .ended, momentum: [])
        bounce.advanceReturn(by: 0.02)
        let bottomStretch = clip.bounds.minY
        _ = bounce.handle(delta: -3, phase: .began, momentum: [])
        precondition(abs(clip.bounds.minY - bottomStretch + 3) < 0.001)
        _ = bounce.handle(delta: 0, phase: .ended, momentum: [])
        for _ in 0..<120 { bounce.advanceReturn(by: 1.0 / 120) }
        precondition(clip.bounds.minY == bottom)
        // Trackpad momentum can outlive the return animation. Neither edge may
        // start a second bounce while the same inertial gesture is still arriving.
        for (edge, outward) in [(top, CGFloat(-1)), (bottom, CGFloat(1))] {
            bounce.cancel()
            place(edge - outward * 5)
            _ = bounce.handle(delta: outward * 80, phase: [], momentum: .began)
            var previousDistance = abs(clip.bounds.minY - edge)
            for _ in 0..<240 {
                _ = bounce.handle(delta: outward * 8, phase: [], momentum: .changed)
                bounce.advanceReturn(by: 1.0 / 120)
                let distance = abs(clip.bounds.minY - edge)
                precondition(distance <= previousDistance, "residual momentum restarts the bounce at \(edge)")
                previousDistance = distance
            }
            precondition(clip.bounds.minY == edge)
            _ = bounce.handle(delta: outward * 2, phase: [], momentum: .ended)
            precondition(clip.bounds.minY == edge, "terminal momentum must not restart the bounce")
            _ = bounce.handle(delta: -outward * 10, phase: .began, momentum: [])
            precondition(clip.bounds.minY == edge - outward * 10, "fresh input must resume immediately")
        }
        print("PASS elastic return, continuous reversal, interruption, in-document continuity, momentum, insets and mouse wheel")
    }
}
