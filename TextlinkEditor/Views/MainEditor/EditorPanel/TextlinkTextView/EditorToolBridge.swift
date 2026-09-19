import AppKit

/// Tools describe their effect, not their own layout/IME/lifecycle plumbing.
struct EditorToolDescriptor {
    enum Category { case documentEdit, presentation, navigation, assistant }
    struct Effects: OptionSet {
        let rawValue: Int
        static let text = Self(rawValue: 1 << 0)
        static let layout = Self(rawValue: 1 << 1)
        static let selection = Self(rawValue: 1 << 2)
    }
    let name: String
    let category: Category
    let effects: Effects
}

final class EditorToolBridge {
    enum Phase { case began, validated, applied, viewportLaidOut, ended }
    enum Outcome { case applied, unchanged, cancelled }
    struct Event {
        let id: UUID
        let tool: EditorToolDescriptor
        let phase: Phase
        let outcome: Outcome
    }
    // Observation only. Events are not retained, and no manuscript text is exposed.
    var onEvent: ((Event) -> Void)?
    private weak var editor: NativeManuscriptTextView?
    private var pending: [(UUID, EditorToolDescriptor)] = []
    private var executing = false

    init(editor: NativeManuscriptTextView) { self.editor = editor }

    func perform(_ tool: EditorToolDescriptor, preservesCursor: Bool = true, isAvailable: Bool = true, operation: () -> Bool) {
        precondition(Thread.isMainThread)
        let id = UUID()
        let nested = executing
        executing = true
        defer { executing = nested }
        emit(id, tool, .began, .applied)
        guard !nested, isAvailable, let editor, !tool.effects.contains(.text) || editor.isEditable else {
            emit(id, tool, .ended, .cancelled)
            return
        }
        emit(id, tool, .validated, .applied)
        if tool.effects.contains(.text) || tool.effects.contains(.selection) { editor.commitComposition() }
        // Opening a tool UI is not a layout mutation and must never reveal the caret.
        let anchor = preservesCursor && tool.category == .presentation && tool.effects.contains(.layout)
            ? editor.scrollCoordinator.capture(for: .appearanceChange) : nil
        let changed = operation()
        emit(id, tool, .applied, changed ? .applied : .unchanged)
        guard changed else { emit(id, tool, .ended, .unchanged); return }
        if tool.effects.contains(.layout) {
            pending.append((id, tool))
            if let anchor { editor.scrollCoordinator.restore(anchor) }
            editor.needsLayout = true
            editor.needsDisplay = true
        } else {
            emit(id, tool, .ended, .applied)
        }
    }

    func viewportDidLayout() {
        guard !executing, editor?.textLayoutManager?.textViewportLayoutController.viewportRange != nil else { return }
        let completed = pending
        pending.removeAll(keepingCapacity: true)
        for (id, tool) in completed {
            emit(id, tool, .viewportLaidOut, .applied)
            emit(id, tool, .ended, .applied)
        }
    }

    func cancelPending() {
        let cancelled = pending
        pending.removeAll(keepingCapacity: true)
        for (id, tool) in cancelled { emit(id, tool, .ended, .cancelled) }
    }

    private func emit(_ id: UUID, _ tool: EditorToolDescriptor, _ phase: Phase, _ outcome: Outcome) {
        onEvent?(Event(id: id, tool: tool, phase: phase, outcome: outcome))
    }
}

struct EditorDisplayStyle: Equatable {
    let fontName: String
    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat
    let letterSpacing: CGFloat
    var key: String { "\(fontName)|\(fontSize)|\(lineHeightMultiple)|\(letterSpacing)" }

    func changedAttributes(from previous: Self?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if previous?.fontName != fontName || previous?.fontSize != fontSize {
            attributes[.font] = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        }
        if previous?.lineHeightMultiple != lineHeightMultiple {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = lineHeightMultiple
            attributes[.paragraphStyle] = paragraph
        }
        if previous?.letterSpacing != letterSpacing { attributes[.kern] = letterSpacing }
        if previous == nil { attributes[.foregroundColor] = AppColors.nsEditorText }
        return attributes
    }
}

extension EditorCommand {
    var tool: EditorToolDescriptor {
        switch action {
        case .tool(let id): return .init(name: id, category: .navigation, effects: [])
        case .format(let kind): return .init(name: "format.\(kind)", category: .documentEdit, effects: [.text, .layout, .selection])
        case .replace: return .init(name: "replace", category: .documentEdit, effects: [.text, .layout, .selection])
        case .find, .locate: return .init(name: "navigate", category: .navigation, effects: [.selection, .layout])
        case .assistantDraft: return .init(name: "assistantDraft", category: .assistant, effects: [])
        }
    }
}
