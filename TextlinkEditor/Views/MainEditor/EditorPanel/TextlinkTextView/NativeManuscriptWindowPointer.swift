import AppKit

/// A drag anchor cannot be an NSTextView-local offset once its paragraph is evicted.
/// Keep the gesture's anchor in document coordinates and let TextKit hit-test each frame.
final class ManuscriptWindowPointer {
    private weak var editor: NativeManuscriptTextView?
    init(editor: NativeManuscriptTextView) { self.editor = editor }

    func track(_ initialEvent: NSEvent) -> Bool {
        guard let editor, let projection = editor.windowedDocument, let window = editor.window,
              initialEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        editor.commitComposition()
        window.makeFirstResponder(editor)
        let previous = editor.documentSelection
        let granularity: NSSelectionGranularity = initialEvent.clickCount >= 3 ? .selectByParagraph
            : initialEvent.clickCount == 2 ? .selectByWord : .selectByCharacter
        func hit(_ location: NSPoint) -> NSRange {
            let point = editor.convert(location, from: nil)
            let offset = min(editor.textStorage?.length ?? 0, editor.characterIndexForInsertion(at: point))
            let local = editor.selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: granularity)
            return NSRange(location: projection.range.location + local.location, length: local.length)
        }
        let first = hit(initialEvent.locationInWindow)
        let fixed: NSRange
        if initialEvent.modifierFlags.contains(.shift) {
            fixed = NSRange(location: first.location < previous.location ? NSMaxRange(previous) : previous.location, length: 0)
        } else { fixed = first }
        func select(at location: NSPoint) {
            let target = hit(location)
            let start = min(fixed.location, target.location)
            let end = max(NSMaxRange(fixed), NSMaxRange(target))
            projection.select(NSRange(location: start, length: end - start), reveal: false)
        }
        select(at: initialEvent.locationInWindow)
        NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var location = initialEvent.locationInWindow
        var dragging = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { break }
            if event.type == .leftMouseDragged { location = event.locationInWindow; dragging = true }
            guard dragging else { continue }
            if let scroll = editor.enclosingScrollView {
                let point = editor.convert(location, from: nil)
                let clip = scroll.contentView
                let delta = point.y < clip.bounds.minY ? max(-80, point.y - clip.bounds.minY)
                    : point.y > clip.bounds.maxY ? min(80, point.y - clip.bounds.maxY) : 0
                if delta != 0 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
                    scroll.reflectScrolledClipView(clip)
                    projection.extendIfNeeded(whileSelecting: true)
                    editor.layoutSubtreeIfNeeded()
                }
            }
            select(at: location)
        }
        return true
    }
}
