import AppKit

final class EditorBounceClipView: NSClipView {
    // Scroll-past-end space belongs to the document extent, not contentInsets:
    // AppKit excludes contentInsets from mouse hit testing and caret visibility.
    var scrollableDocumentHeight: CGFloat = 0
    override var documentRect: NSRect {
        var rect = super.documentRect
        if let documentView {
            let document = convert(documentView.bounds, from: documentView)
            rect.size.height = max(rect.height, document.minY + scrollableDocumentHeight - rect.minY)
        }
        return rect
    }
    var allowsTopStretch = false
    var allowsBottomStretch = false
    func documentBounds(_ proposed: NSRect) -> NSRect { super.constrainBoundsRect(proposed) }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        if allowsTopStretch { constrained.origin.y = min(constrained.minY, proposedBounds.minY) }
        if allowsBottomStretch { constrained.origin.y = max(constrained.minY, proposedBounds.minY) }
        return constrained
    }
}

/// One owner for vertical wheel movement and edge return. Mixing native animated
/// wheel movement with a custom edge return lets two animators mutate the clip.
final class EditorScrollMotion {
    private weak var scroll: NSScrollView?
    private var timer: Timer?
    private var previousTick: TimeInterval = 0
    private var ownsStretch = false
    private var stretchesTop = true
    // The input gesture can keep sending momentum after the spring has settled.
    // Retain this until fresh direct input, independently of animation lifetime.
    private var suppressesMomentum = false

    init(scroll: NSScrollView) { self.scroll = scroll }
    deinit { timer?.invalidate() }

    func handle(_ event: NSEvent) -> Bool {
        guard let scroll else { return false }
        let delta = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : scroll.verticalLineScroll)
        return handle(delta: delta, phase: event.phase, momentum: event.momentumPhase)
    }

    // Kept separate from NSEvent so gesture transitions can be exercised without
    // synthesizing system input or depending on the user's trackpad settings.
    func handle(delta: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        guard let scroll, scroll.documentView != nil else { return false }
        let clip = scroll.contentView
        let top = boundary(clip, top: true)
        let bottom = boundary(clip, top: false)
        let y = clip.bounds.minY
        if !momentum.isEmpty && (suppressesMomentum || ownsStretch) {
            startReturn()
            return true
        }
        if momentum.isEmpty && (phase.isEmpty || phase.contains(.began) || phase.contains(.changed)) {
            suppressesMomentum = false
        }
        cancelReturn()
        let target = y + delta
        let above = y < top || target < top
        let below = y > bottom || target > bottom
        var next = target
        if above || below {
            let edge = above ? top : bottom
            let sign: CGFloat = above ? -1 : 1
            let stretch = max(0, (y - edge) * sign)
            let outward = delta * sign
            if outward > 0 {
                let inside = max(0, (edge - y) * sign)
                let beyond = max(0, outward - inside)
                let resistance = 0.35 / (1 + stretch / 120)
                next = edge + sign * (stretch + beyond * resistance)
            }
        }
        ownsStretch = next < top || next > bottom
        stretchesTop = next < top
        if let clip = clip as? EditorBounceClipView {
            clip.allowsTopStretch = next < top
            clip.allowsBottomStretch = next > bottom
        }
        if delta != 0 {
            var point = clip.bounds.origin
            point.y = next
            clip.setBoundsOrigin(point)
            scroll.reflectScrolledClipView(clip)
        }
        if !momentum.isEmpty || phase.contains(.ended) || phase.contains(.cancelled) || phase.isEmpty {
            startReturn()
        }
        return true
    }

    func cancel() {
        suppressesMomentum = false
        finishReturn()
    }

    private func finishReturn() {
        cancelReturn()
        ownsStretch = false
        (scroll?.contentView as? EditorBounceClipView)?.allowsTopStretch = false
        (scroll?.contentView as? EditorBounceClipView)?.allowsBottomStretch = false
    }

    private func boundary(_ clip: NSClipView, top: Bool) -> CGFloat {
        var proposed = clip.bounds
        proposed.origin.y = top
            ? clip.documentRect.minY - clip.bounds.height - abs(clip.contentInsets.top) - 1
            : clip.documentRect.maxY + clip.bounds.height + abs(clip.contentInsets.bottom) + 1
        return (clip as? EditorBounceClipView)?.documentBounds(proposed).minY
            ?? clip.constrainBoundsRect(proposed).minY
    }

    private func cancelReturn() {
        timer?.invalidate()
        timer = nil
    }

    private func startReturn() {
        guard ownsStretch, timer == nil else { return }
        suppressesMomentum = true
        previousTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.advanceReturn(by: now - self.previousTick)
            self.previousTick = now
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advanceReturn(by elapsed: TimeInterval) {
        guard ownsStretch, let scroll else { finishReturn(); return }
        let clip = scroll.contentView
        let edge = boundary(clip, top: stretchesTop)
        let sign: CGFloat = stretchesTop ? -1 : 1
        let distance = (clip.bounds.minY - edge) * sign
        guard distance > 0 else { finishReturn(); return }
        var point = clip.bounds.origin
        // Clip views align their bounds to backing pixels; finish before rounding
        // can leave a subpixel step repeating forever.
        let pixel = 1 / (scroll.window?.backingScaleFactor ?? 1)
        let step = max(pixel, distance * (1 - exp(-18 * max(0, elapsed))))
        let remaining = max(0, distance - step)
        let finished = remaining < pixel
        point.y = finished ? edge : edge + sign * remaining
        clip.setBoundsOrigin(point)
        scroll.reflectScrolledClipView(clip)
        if finished { finishReturn() }
    }
}
