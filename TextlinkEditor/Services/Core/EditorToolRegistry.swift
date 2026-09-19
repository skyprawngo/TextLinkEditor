import AppKit

/// Built-in identity is independent of labels, enum descriptions and localization.
/// Dynamic tools keep their own stable string IDs through the same registry.
enum EditorToolID: String, CaseIterable {
    case bold = "format.bold"
    case italic = "format.italic"
    case boldItalic = "format.boldItalic"
    case underline = "format.underline"
    case strikethrough = "format.strikethrough"
    case markdownPreview = "display.markdownPreview"
    case font = "display.font"
    case fontSize = "display.fontSize"
    case lineSpacing = "display.lineSpacing"
    case letterSpacing = "display.letterSpacing"
    case inline = "ai.inline"
    case attachSelection = "ai.attachSelection"
    case collaborationComment = "ai.collaborationComment"
    case continueWriting = "ai.continueWriting"
    case refine = "ai.refine"
    case summarize = "ai.summarize"
    case styleConvert = "ai.styleConvert"
    case consistencyCheck = "ai.consistencyCheck"
}

/// A tool is declared once. Settings, keyboard routing, and toolbar lists consume
/// this catalog; merely opening the settings never executes a tool.
protocol EditorToolTarget: AnyObject {
    func runTool(_ definition: EditorToolDefinition)
    func toolFormat(_ kind: String)
    func toolAssistant(_ titleKey: String)
    func toolPresent(_ control: String)
    func toolToggleInline()
    func toolAttachSelection()
}

struct EditorToolDefinition: Identifiable {
    enum Category: String { case edit, view, ai }
    enum Impact { case text, presentation, selection, request }
    let id: String
    let titleKey: String
    let category: Category
    let impact: Impact
    var key: String = ""
    var modifiers: NSEvent.ModifierFlags = []
    var requiresSelection: Bool = false
    let operation: (EditorToolTarget) -> Void
}

enum EditorToolRegistry {
    static let executionRequested = Notification.Name("executeEditorTool")

    /// UI adapters request a registered ID; the active document owns execution.
    @discardableResult
    static func requestExecution(_ id: String) -> Bool {
        guard definition(id) != nil else { return false }
        NotificationCenter.default.post(name: executionRequested, object: id)
        return true
    }

    static let didRegister = Notification.Name("editorToolsDidRegister")
    private(set) static var tools: [EditorToolDefinition] = [
        tool(EditorToolID.bold.rawValue, "editor.bold", .edit, .text, requiresSelection: true) { $0.toolFormat("bold") },
        tool(EditorToolID.italic.rawValue, "editor.italic", .edit, .text, requiresSelection: true) { $0.toolFormat("italic") },
        tool(EditorToolID.boldItalic.rawValue, "toolbar.boldItalic", .edit, .text, requiresSelection: true) { $0.toolFormat("boldItalic") },
        tool(EditorToolID.underline.rawValue, "editor.underline", .edit, .text, requiresSelection: true) { $0.toolFormat("underline") },
        tool(EditorToolID.strikethrough.rawValue, "editor.strikethrough", .edit, .text, requiresSelection: true) { $0.toolFormat("strikethrough") },
        tool(EditorToolID.markdownPreview.rawValue, "editor.markdown.toggle", .view, .presentation) { $0.toolPresent("markdownPreview") },
        tool(EditorToolID.font.rawValue, "settings.editor.fontName", .view, .presentation) { $0.toolPresent("font") },
        tool(EditorToolID.fontSize.rawValue, "editor.fontSize", .view, .presentation) { $0.toolPresent("fontSize") },
        tool(EditorToolID.lineSpacing.rawValue, "editor.lineSpacing", .view, .presentation) { $0.toolPresent("lineSpacing") },
        tool(EditorToolID.letterSpacing.rawValue, "editor.letterSpacing", .view, .presentation) { $0.toolPresent("letterSpacing") },
        tool(EditorToolID.inline.rawValue, "ai.inline.open", .ai, .selection, key: "i", modifiers: [.command]) { $0.toolToggleInline() },
        tool(EditorToolID.attachSelection.rawValue, "ai.context.attachSelection", .ai, .request, requiresSelection: true) { $0.toolAttachSelection() },
        tool(EditorToolID.collaborationComment.rawValue, "collaboration.commentSelection", .ai, .request, requiresSelection: true) { $0.toolAssistant("collaboration.commentSelection") },
        tool(EditorToolID.continueWriting.rawValue, "ai.continueWriting", .ai, .request, key: "return", modifiers: [.command, .shift]) { $0.toolAssistant("ai.continueWriting") },
        tool(EditorToolID.refine.rawValue, "ai.refineText", .ai, .request, key: "r", modifiers: [.command, .shift]) { $0.toolAssistant("ai.refineText") },
        tool(EditorToolID.summarize.rawValue, "ai.summarize", .ai, .request, key: "u", modifiers: [.command, .shift]) { $0.toolAssistant("ai.summarize") },
        tool(EditorToolID.styleConvert.rawValue, "ai.styleConvert", .ai, .request) { $0.toolAssistant("ai.styleConvert") },
        tool(EditorToolID.consistencyCheck.rawValue, "ai.consistencyCheck", .ai, .request) { $0.toolAssistant("ai.consistencyCheck") }
    ]

    static func tool(_ id: String, _ titleKey: String, _ category: EditorToolDefinition.Category,
                     _ impact: EditorToolDefinition.Impact, key: String = "", modifiers: NSEvent.ModifierFlags = [], requiresSelection: Bool = false,
                     operation: @escaping (EditorToolTarget) -> Void) -> EditorToolDefinition {
        EditorToolDefinition(id: id, titleKey: titleKey, category: category, impact: impact,
                             key: key, modifiers: modifiers, requiresSelection: requiresSelection, operation: operation)
    }

    static func register(_ definition: EditorToolDefinition) {
        precondition(Thread.isMainThread)
        precondition(definition.id.contains(".") && !tools.contains { $0.id == definition.id }, "Duplicate/invalid tool ID")
        tools.append(definition)
        NotificationCenter.default.post(name: didRegister, object: nil)
    }

    static func definition(_ id: String) -> EditorToolDefinition? { tools.first { $0.id == id } }
    static func title(for id: String) -> String { definition(id).map { L10n.get($0.titleKey) } ?? id }
    /// Returns whether the ID was recognized; execution outcome is reported by the target lifecycle.
    @discardableResult static func perform(_ id: String, on target: EditorToolTarget) -> Bool {
        guard let definition = definition(id) else { return false }
        target.runTool(definition)
        return true
    }
}
