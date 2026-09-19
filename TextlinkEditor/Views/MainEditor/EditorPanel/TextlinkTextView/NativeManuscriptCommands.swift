import AppKit

/// Source-edit and tool dispatch; AppKit input and layout are owned by the view.
extension NativeManuscriptTextView {
    func runTool(_ definition: EditorToolDefinition) {
        let effects: EditorToolDescriptor.Effects
        let category: EditorToolDescriptor.Category
        switch definition.impact {
        case .text: effects = [.text, .selection, .layout]; category = .documentEdit
        case .selection: effects = [.selection, .layout]; category = .navigation
        case .presentation: effects = []; category = .presentation
        case .request: effects = []; category = .assistant
        }
        let hasRequiredSelection = !definition.requiresSelection || documentSelection.length > 0
        let canPresent = definition.impact != .presentation || onToolPresentation != nil
        let canToggleInline = definition.id != EditorToolID.inline.rawValue || isEditable || inlinePanel != nil
        toolBridge.perform(.init(name: definition.id, category: category, effects: effects),
                           isAvailable: hasRequiredSelection && canPresent && canToggleInline) {
            let generation = self.textEditGeneration
            let selection = self.documentSelection
            let panel = self.inlinePanel
            definition.operation(self)
            return generation != self.textEditGeneration || selection != self.documentSelection || panel !== self.inlinePanel
                || definition.impact == .request || definition.impact == .presentation
        }
    }
    func toolFormat(_ kind: String) {
        let formats: [String: MarkdownFormatType] = ["bold": .bold, "italic": .italic, "boldItalic": .boldItalic,
                                                    "underline": .underline, "strikethrough": .strikethrough]
        if let format = formats[kind] { applyCommand(EditorCommand(.format(format))) }
    }
    func toolAssistant(_ titleKey: String) {
        if titleKey == "collaboration.commentSelection" {
            NotificationCenter.default.post(name: .init("collaborationCommentRequested"), object: nil)
        } else { applyCommand(EditorCommand(.assistantDraft(L10n.get(titleKey)))) }
    }
    func toolPresent(_ control: String) { onToolPresentation?(control) }
    func toolAttachSelection() {
        guard documentSelection.length > 0 else { return }
        let text = (documentText as NSString).substring(with: documentSelection)
        NotificationCenter.default.post(name: Notification.Name("aiAttachSelection"), object: text)
    }

    func execute(_ command: EditorCommand) {
        if case .tool(let id) = command.action { EditorToolRegistry.perform(id, on: self); return }
        toolBridge.perform(command.tool) {
            let generation = self.textEditGeneration
            let selection = self.documentSelection
            self.applyCommand(command)
            return generation != self.textEditGeneration || selection != self.documentSelection || command.tool.category == .assistant
        }
    }

    func applyCommand(_ command: EditorCommand) {
        switch command.action {
        case .tool: return
        case .assistantDraft(let action):
            NotificationCenter.default.post(name: Notification.Name("aiDraftAction"), object: action)
            return
        case .locate(let line, let query):
            let start = windowedDocument?.document.offset(line: line, column: 0) ?? offset(line: line, column: 0)
            let source = documentText as NSString
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let match = source.range(of: query, options: .caseInsensitive, range: lineRange)
            selectDocumentRange(match.location == NSNotFound ? NSRange(location: start, length: 0) : match)
        case .find(let query, let forward): find(query, forward: forward)
        case .replace(let query, let replacement, let all):
            guard !query.isEmpty, isEditable else { return }
            if all {
                let result = documentText.replacingOccurrences(of: query, with: replacement)
                if result != documentText { replaceDocument(NSRange(location: 0, length: documentText.utf16.count), with: result) }
            } else {
                if (documentText as NSString).substring(with: documentSelection) != query { find(query, forward: true) }
                if (documentText as NSString).substring(with: documentSelection) == query { replaceDocument(documentSelection, with: replacement) }
            }
        case .format(let type):
            guard documentSelection.length > 0 else { return }
            let markers: (String, String)
            switch type {
            case .bold: markers = ("**", "**")
            case .italic: markers = ("*", "*")
            case .boldItalic: markers = ("***", "***")
            case .underline: markers = ("<u>", "</u>")
            case .strikethrough: markers = ("~~", "~~")
            }
            let selected = (documentText as NSString).substring(with: documentSelection)
            let result = selected.hasPrefix(markers.0) && selected.hasSuffix(markers.1) && selected.count >= markers.0.count + markers.1.count
                ? String(selected.dropFirst(markers.0.count).dropLast(markers.1.count)) : markers.0 + selected + markers.1
            replaceDocument(documentSelection, with: result, selectReplacement: true)
        }
        scrollCoordinator.revealSelection()
    }
    private func find(_ query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        let value = documentText as NSString
        let selection = documentSelection
        let offset = forward ? NSMaxRange(selection) : selection.location
        let first = forward ? NSRange(location: offset, length: value.length - offset) : NSRange(location: 0, length: offset)
        let options: NSString.CompareOptions = forward ? [] : [.backwards]
        var match = value.range(of: query, options: options, range: first)
        if match.location == NSNotFound { match = value.range(of: query, options: options) }
        if match.location != NSNotFound { selectDocumentRange(match) }
    }
}
