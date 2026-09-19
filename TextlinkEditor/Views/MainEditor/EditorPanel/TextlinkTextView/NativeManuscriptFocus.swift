import AppKit

/// Sidebar ownership survives asynchronous document loading; an explicit editor or
/// tab click releases it. The native text view itself does not own global UI focus.
enum EditorFocusCoordinator {
    private(set) static weak var sidebarWindow: NSWindow?

    static func claimSidebar(in window: NSWindow?) {
        guard let window else { return }
        sidebarWindow = window
        if let editor = window.firstResponder as? NativeManuscriptTextView {
            editor.commitComposition()
            window.makeFirstResponder(nil)
        }
    }

    static func claimEditor(in window: NSWindow?) {
        if sidebarWindow === window { sidebarWindow = nil }
    }

    static func permitsAutomaticFocus(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return sidebarWindow !== window
    }
}
