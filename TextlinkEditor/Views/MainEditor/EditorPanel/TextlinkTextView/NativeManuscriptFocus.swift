import AppKit

/// Window-local intent plus the actual responder decide whether delayed document
/// loading may focus the manuscript. Selection publication does not own focus.
enum EditorFocusCoordinator {
    private static let sidebarWindows = NSHashTable<NSWindow>.weakObjects()

    static func claimSidebar(in window: NSWindow?) {
        guard let window else { return }
        sidebarWindows.add(window)
        if let editor = window.firstResponder as? NativeManuscriptTextView {
            editor.commitComposition()
            window.makeFirstResponder(nil)
        }
    }

    static func claimEditor(in window: NSWindow?) {
        guard let window else { return }
        sidebarWindows.remove(window)
    }

    static func permitsAutomaticFocus(in window: NSWindow?) -> Bool {
        guard let window, !sidebarWindows.contains(window) else { return false }
        // AI composer, rename field, search and toolbar inputs own their responder.
        // A queued document-load callback must not steal it from any of them.
        if let responder = window.firstResponder {
            if responder is NativeManuscriptTextView { return true }
            if responder is NSText || responder is NSControl { return false }
        }
        return true
    }
}
