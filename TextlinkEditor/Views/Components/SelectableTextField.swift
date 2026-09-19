//
//  SelectableTextField.swift
//  TextlinkEditor
//
//  텍스트 선택 범위를 지정할 수 있는 NSTextField 래퍼
//

import SwiftUI
import AppKit

/// 초기 텍스트 선택 범위를 지정할 수 있는 텍스트 필드
struct SelectableTextField: NSViewRepresentable {
    @Binding var text: String
    /// 선택할 텍스트 범위 (문자 인덱스)
    var selectRange: Range<Int>
    /// 엔터 키 입력 시 호출
    var onCommit: () -> Void
    /// ESC 키 입력 시 호출
    var onCancel: () -> Void
    /// 포커스를 잃었을 때 호출 (외부 클릭 시)
    var onFocusLost: (() -> Bool)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        context.coordinator.observeOutsideClicks(of: textField)
        textField.stringValue = text
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .exterior
        textField.backgroundColor = NSColor.controlBackgroundColor

        // 초기 선택 범위 설정 및 포커스
        DispatchQueue.main.async {
            guard !context.coordinator.hasEnded, textField.window != nil else { return }
            textField.window?.makeFirstResponder(textField)
            if let fieldEditor = textField.window?.fieldEditor(true, for: textField) as? NSTextView {
                fieldEditor.selectedRange = NSRange(
                    location: String(text.prefix(selectRange.lowerBound)).utf16.count,
                    length: String(text.dropFirst(selectRange.lowerBound).prefix(selectRange.count)).utf16.count
                )
            }
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.hasEnded = true
        coordinator.stopObserving()
        nsView.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectableTextField
        var hasEnded = false
        private weak var textField: NSTextField?
        private var mouseMonitor: Any?

        func observeOutsideClicks(of field: NSTextField) {
            textField = field
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, !self.hasEnded, let field = self.textField,
                      let window = field.window else { return event }
                if event.window === window,
                   field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                // Blank views need not take first responder, so focus loss alone is insufficient.
                return self.requestEndEditing() ? event : nil
            }
        }

        func stopObserving() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
        }

        deinit { stopObserving() }

        @discardableResult
        private func requestEndEditing() -> Bool {
            guard !hasEnded else { return true }
            hasEnded = true // Prevent reentry while a discard alert runs its modal loop.
            let accepted = parent.onFocusLost?() ?? true
            if !accepted {
                hasEnded = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.hasEnded, let field = self.textField else { return }
                    field.window?.makeFirstResponder(field)
                }
            }
            return accepted
        }

        init(_ parent: SelectableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // 포커스를 잃었을 때 (외부 클릭 등)
            requestEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Enter 키
                guard !hasEnded else { return true }
                hasEnded = true
                parent.onCommit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // ESC 키
                guard !hasEnded else { return true }
                hasEnded = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SelectableTextField(
            text: .constant("example.txt"),
            selectRange: 0..<7,
            onCommit: { print("Commit") },
            onCancel: { print("Cancel") }
        )
        .frame(width: 200)
    }
    .padding(40)
}
