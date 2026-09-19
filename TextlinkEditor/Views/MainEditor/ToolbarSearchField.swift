import SwiftUI

// MARK: - Toolbar Search Field

final class ToolbarNativeSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// 툴바용 NSSearchField 래퍼
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var onSearch: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = ToolbarNativeSearchField()
        searchField.placeholderString = prompt
        searchField.delegate = context.coordinator
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else { return }
            searchField.window?.makeFirstResponder(searchField)
        }
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.onSearch = onSearch
        context.coordinator.onCancel = onCancel
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSearch: onSearch)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        var onCancel: () -> Void = {}
        var onSearch: () -> Void
        init(text: Binding<String>, onSearch: @escaping () -> Void) {
            _text = text
            self.onSearch = onSearch
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onCancel(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { onSearch(); return true }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // Let AppKit finish transferring the responder before removing the field.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let field, field.currentEditor() == nil,
                      field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self?.onCancel()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let searchField = obj.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}
