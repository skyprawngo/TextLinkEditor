import AppKit

/// Read-only TextKit geometry, in container coordinates.
extension NativeManuscriptTextView {
    /// All geometry is in the TextKit 2 container coordinate system. Never access
    /// NSTextView.layoutManager: that would silently enable TextKit 1 compatibility.
    func textLocation(at offset: Int) -> (any NSTextLocation)? {
        guard let content = textLayoutManager?.textContentManager else { return nil }
        return content.location(content.documentRange.location, offsetBy: min(max(0, offset), textStorage?.length ?? 0))
    }

    func layoutFragment(at location: any NSTextLocation) -> NSTextLayoutFragment? {
        guard let manager = textLayoutManager else { return nil }
        if let fragment = manager.textLayoutFragment(for: location) { return fragment }
        // Empty documents / trailing empty paragraphs have a zero-length fragment.
        // A location lookup can miss it; enumeration includes that cached fragment.
        var result: NSTextLayoutFragment?
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresExtraLineFragment]) { fragment in
            result = fragment
            return false
        }
        if result == nil, let content = manager.textContentManager,
           location.compare(content.documentRange.endLocation) == .orderedSame,
           let previous = content.location(location, offsetBy: -1) {
            result = manager.textLayoutFragment(for: previous)
        }
        return result
    }

    func lineRect(at offset: Int) -> NSRect? {
        guard let location = textLocation(at: offset),
              let fragment = layoutFragment(at: location),
              fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false)
                ?? (offset == textStorage?.length ? fragment.textLineFragments.last : nil) else { return nil }
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                               dy: fragment.layoutFragmentFrame.minY)
    }

    /// Enumerate only already-laid-out viewport fragments; accessories never lay out
    /// the entire document just to obtain line numbers or selection backgrounds.
    func visibleManuscriptLines() -> [(row: Int, rect: NSRect)] {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        let visible = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        var lines: [(row: Int, rect: NSRect)] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            // Unlaid-out fragments have zero geometry. Testing their Y coordinate
            // alone walks to EOF and materializes the rest of a large document.
            // Bound traversal by text locations before reading any geometry.
            guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending,
                  fragment.state == .layoutAvailable else { return false }
            guard fragment.layoutFragmentFrame.minY <= visible.maxY else { return false }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let offset = start + lineFragment.characterRange.location
                let row = self.line(at: offset)
                // Soft-wrapped continuation lines have no separate manuscript number.
                guard self.lineStarts[row] == offset else { continue }
                let frame = lineFragment.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                                    dy: fragment.layoutFragmentFrame.minY)
                if frame.maxY >= visible.minY && frame.minY <= visible.maxY { lines.append((row, frame)) }
            }
            return true
        }
        return lines
    }

}
