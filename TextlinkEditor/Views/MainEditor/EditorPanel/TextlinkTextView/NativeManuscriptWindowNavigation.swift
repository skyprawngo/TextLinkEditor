import AppKit

/// AppKit computes visual-line/word movement inside the current window. Selection
/// endpoints remain document offsets, including a selection larger than TextKit's window.
final class ManuscriptWindowNavigation {
    private weak var editor: NativeManuscriptTextView?
    private var anchor: Int?
    private var head: Int?
    private var lastSelection: NSRange?

    init(editor: NativeManuscriptTextView) { self.editor = editor }

    func reset() { anchor = nil; head = nil; lastSelection = nil }

    func perform(_ selector: Selector, native: (Selector) -> Void) -> Bool {
        guard let editor, let window = editor.windowedDocument else { return false }
        let name = NSStringFromSelector(selector)
        let modifying = name.contains("AndModifySelection")
        let movement = name.replacingOccurrences(of: "AndModifySelection", with: "")
        let supported: Set<String> = ["moveLeft:", "moveRight:", "moveBackward:", "moveForward:",
            "moveUp:", "moveDown:", "moveWordLeft:", "moveWordRight:", "moveWordBackward:", "moveWordForward:",
            "moveToBeginningOfLine:", "moveToEndOfLine:", "moveToBeginningOfParagraph:", "moveToEndOfParagraph:",
            "moveParagraphBackward:", "moveParagraphForward:", "moveToBeginningOfDocument:", "moveToEndOfDocument:",
            "pageUp:", "pageDown:"]
        guard supported.contains(movement) else {
            if name.hasPrefix("delete"), window.hasVirtualSelection, editor.documentSelection.length > 0 {
                window.replace(editor.documentSelection, with: "")
                reset()
                return true
            }
            return false
        }
        if !modifying && (movement == "pageUp:" || movement == "pageDown:") {
            editor.scrollCoordinator.cancel()
            native(selector)
            window.extendIfNeeded()
            return true
        }
        let selection = editor.documentSelection
        let backwards = movement.contains("Left") || movement.contains("Backward") || movement.contains("Beginning")
            || movement == "moveUp:" || movement == "pageUp:"
        if lastSelection != selection { reset() }
        let start = head ?? (backwards ? selection.location : NSMaxRange(selection))
        let fixed = anchor ?? (backwards ? NSMaxRange(selection) : selection.location)
        let destination: Int
        if movement == "moveToBeginningOfDocument:" { destination = 0 }
        else if movement == "moveToEndOfDocument:" { destination = window.document.length }
        else if !modifying, selection.length > 0,
                ["moveLeft:", "moveRight:", "moveBackward:", "moveForward:"].contains(movement) {
            destination = backwards ? selection.location : NSMaxRange(selection)
        } else {
            window.select(NSRange(location: start, length: 0), reveal: false)
            window.prepareForInput()
            native(NSSelectorFromString(movement))
            destination = editor.documentSelection.location
        }
        if modifying {
            let selection = NSRange(location: min(fixed, destination), length: abs(destination - fixed))
            window.select(selection, focus: destination)
            anchor = fixed; head = destination; lastSelection = selection
        } else {
            window.select(NSRange(location: destination, length: 0))
            reset()
        }
        return true
    }
}
