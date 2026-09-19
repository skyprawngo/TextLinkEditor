import SwiftUI
import AppKit

// MARK: - 다중 줄 입력 뷰

/// 다중 줄 입력을 지원하는 텍스트 입력 뷰 (Shift+Enter로 줄바꿈, Enter로 전송)
/// 텍스트 내용에 따라 높이가 자동으로 확장됩니다 (minHeight ~ maxHeight)
struct MultiLineInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let placeholder: String
    let isDisabled: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    var onModeSelected: ((AIChatMode) -> Void)?
    var focusRequest: Int

    init(
        text: Binding<String>,
        contentHeight: Binding<CGFloat>,
        placeholder: String,
        isDisabled: Bool,
        minHeight: CGFloat = 32,
        maxHeight: CGFloat = 120,
        onSubmit: @escaping () -> Void,
        onModeSelected: ((AIChatMode) -> Void)? = nil,
        focusRequest: Int = 0
    ) {
        self._text = text
        self._contentHeight = contentHeight
        self.placeholder = placeholder
        self.isDisabled = isDisabled
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.onSubmit = onSubmit
        self.onModeSelected = onModeSelected
        self.focusRequest = focusRequest
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = InputScrollView()
        let textView = InputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: minHeight))

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = NSColor(AppColors.textPrimary)
        textView.insertionPointColor = NSColor(AppColors.accent)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isRichText = false
        textView.allowsUndo = true

        context.coordinator.textView = textView

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // 초기 높이 계산
        DispatchQueue.main.async {
            context.coordinator.updateContentHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let shouldFocus = context.coordinator.parent.focusRequest != focusRequest
        context.coordinator.parent = self
        if shouldFocus && !isDisabled { textView.window?.makeFirstResponder(textView) }
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            textView.undoManager?.removeAllActions()
            // 텍스트가 외부에서 변경된 경우 높이 재계산
            DispatchQueue.main.async {
                context.coordinator.updateContentHeight()
            }
        }

        textView.isEditable = !isDisabled
        context.coordinator.updatePlaceholder()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineInputView
        weak var textView: NSTextView?
        private var placeholderLabel: NSTextField?

        init(_ parent: MultiLineInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !textView.hasMarkedText(), let onModeSelected = parent.onModeSelected,
               let draft = AIChatMode.extractDraftTag(textView.string, selection: textView.selectedRange()) {
                onModeSelected(draft.mode)
                textView.string = draft.body
                textView.setSelectedRange(draft.selection)
                // Native undo entries refer to the command text removed from this draft.
                textView.undoManager?.removeAllActions()
            }
            parent.text = textView.string
            updatePlaceholder()
            updateContentHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if textView.hasMarkedText() { return false }
                if !parent.text.isEmpty && !parent.isDisabled {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        /// 텍스트 내용에 따른 높이 계산 및 업데이트
        func updateContentHeight() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // 레이아웃 강제 수행
            layoutManager.ensureLayout(for: textContainer)

            // 텍스트 콘텐츠의 실제 높이 계산
            let usedRect = layoutManager.usedRect(for: textContainer)
            let insetHeight = textView.textContainerInset.height * 2

            // 계산된 높이 (최소/최대 범위 내)
            let calculatedHeight = usedRect.height + insetHeight
            let clampedHeight = min(max(calculatedHeight, parent.minHeight), parent.maxHeight)

            // 높이가 변경된 경우에만 업데이트
            if abs(parent.contentHeight - clampedHeight) > 0.5 {
                parent.contentHeight = clampedHeight
            }

            // 스크롤 가능 여부 설정 (최대 높이에 도달한 경우)
            if let scrollView = textView.enclosingScrollView {
                scrollView.hasVerticalScroller = calculatedHeight > parent.maxHeight
            }
        }

        func updatePlaceholder() {
            guard let textView = textView else { return }

            if placeholderLabel == nil {
                let label = InputPlaceholderLabel(labelWithString: parent.placeholder)
                label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                label.textColor = NSColor.placeholderTextColor
                label.backgroundColor = .clear
                label.isBordered = false
                label.isEditable = false
                label.isSelectable = false
                label.translatesAutoresizingMaskIntoConstraints = false

                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 4)
                ])

                placeholderLabel = label
            }

            placeholderLabel?.stringValue = parent.placeholder
            placeholderLabel?.isHidden = !textView.string.isEmpty
        }
    }
}

private final class InputPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        text.minSize = NSSize(width: 0, height: max(1, contentSize.height))
        text.setFrameSize(NSSize(width: width, height: max(contentSize.height, text.frame.height)))
        text.textContainer?.containerSize.width = width
    }
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? NSTextView { window?.makeFirstResponder(text) }
        super.mouseDown(with: event)
    }
}

private class InputTextView: NSTextView {
    // NSTextView owns composed-character edits, IME groups, selection replacement, and delegate notifications.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
}

// MARK: - 대화 카드 뷰
// Conversation summaries are presented in the history sheet.
