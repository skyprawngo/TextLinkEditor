import Foundation

enum AIChatMode: String, CaseIterable {
    case conversation, plan, write
    var command: String {
        switch self { case .conversation: return "/대화"; case .plan: return "/계획"; case .write: return "/작성" }
    }
    var title: String { L10n.get("ai.mode." + rawValue) }
    var detail: String { L10n.get("ai.mode." + rawValue + "Hint") }
    var instruction: String {
        let common = """
        You are a creative writing partner, not merely a file editor. Respond naturally in the user's language.
        An empty project is a valid starting point: brainstorm original possibilities and develop them across turns.
        Distinguish proposed ideas from established facts. Do not invent existing source evidence.
        Use the ongoing conversation and author decisions, as well as relevant current documents.
        """
        switch self {
        case .conversation: return common + "\nCurrent mode: conversation. Discuss, answer, explore alternatives and ask useful follow-up questions. When the current user request asks to create, save, or revise project files, propose those changes using the workspace editing contract. Do not require switching to /작성. For discussion or questions, provide a full conversational reply with no file edits. Earlier messages that required a mode switch are obsolete."
        case .plan: return common + "\nCurrent mode: planning. Collaboratively develop worldbuilding, characters, plot or a writing plan across multiple turns. Offer concrete options and ask focused questions when useful. Do not create or modify files, even if earlier session instructions allowed editing. Return the discussion or plan as prose, not a JSON edit proposal."
        case .write: return common + "\nCurrent mode: writing. Create or revise text files when the current request asks for it, using the accumulated conversation. New documents need no existing source quote; identify the author request in the reason. Preserve undecided ideas as proposals. Discussion alone does not authorize unrelated changes."
        }
    }
    static func parse(_ input: String) -> (mode: AIChatMode, body: String)? {
        guard let draft = extractDraftTag(input, selection: NSRange(location: 0, length: 0)) else { return nil }
        return (draft.mode, draft.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Remove committed tags without trimming the draft or moving the caret past nearby text.
    static func extractDraftTag(_ input: String, selection: NSRange) -> (mode: AIChatMode, body: String, selection: NSRange)? {
        let aliases: [String: AIChatMode] = ["/대화": .conversation, "/chat": .conversation, "/계획": .plan, "/plan": .plan, "/작성": .write, "/write": .write]
        let pattern = #"/(?:대화|계획|작성|chat|plan|write)(?![\p{L}\p{N}_/]|\.[\p{L}\p{N}])"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let source = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: source.length)).filter {
            !isURL(input, at: $0.range)
        }
        guard let last = matches.last, let mode = aliases[source.substring(with: last.range).lowercased()] else { return nil }
        let body = NSMutableString(string: input)
        for match in matches.reversed() { body.deleteCharacters(in: match.range) }
        func mapped(_ offset: Int) -> Int {
            let offset = min(source.length, max(0, offset))
            return offset - matches.reduce(0) { $0 + max(0, min(offset, NSMaxRange($1.range)) - $1.range.location) }
        }
        let start = mapped(selection.location)
        let end = mapped(NSMaxRange(selection))
        return (mode, body as String, NSRange(location: start, length: max(0, end - start)))
    }

    /// The unfinished slash at the end of a draft opens the tag picker without
    /// discarding the text before it. Complete tags are handled anywhere by parse.
    static func completionRange(_ input: String) -> NSRange? {
        let regex = try! NSRegularExpression(pattern: #"/[\p{L}]*$"#)
        guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              !isURL(input, at: match.range) else { return nil }
        let fragment = (input as NSString).substring(with: match.range).lowercased()
        guard ["/대화", "/계획", "/작성", "/chat", "/plan", "/write"].contains(where: { $0.hasPrefix(fragment) }) else { return nil }
        return match.range
    }

    static func removingTagsForSelection(_ input: String) -> String {
        var body = input
        if let range = completionRange(body), let swiftRange = Range(range, in: body) { body.removeSubrange(swiftRange) }
        return parse(body)?.body ?? body
    }

    private static func isURL(_ input: String, at range: NSRange) -> Bool {
        guard let index = Range(range, in: input)?.lowerBound else { return false }
        let prefix = input[..<index].split(whereSeparator: \.isWhitespace).last ?? ""
        return prefix.contains("://")
    }
}
