import Foundation

/// A submission owns its text and context, independently of the next composer draft.
struct AIQueuedMessage: Identifiable {
    let id: UUID
    let text: String
    let conversationID: UUID
    let project: URL
    let provider: AICLIType
    let mode: AIChatMode
    let options: AIRequestOptions
    let taggedIDs: Set<UUID>
    let document: ManuscriptRevision?
    let context: AIContextManifest

    func steeringInstruction() throws -> String {
        var instruction = text
        if let document { instruction += "\n\nAttached document (source material):\n" + document.original }
        if !context.text.isEmpty { instruction += "\n\n" + context.text }
        instruction += "\n\nContinue this same turn. Preserve the current output format and workspace proposal contract."
        guard instruction.utf8.count <= 1_000_000 else {
            throw AIRequestPreparationError.message(L10n.get("ai.error.contextTooLarge"))
        }
        return instruction
    }
}

/// Stable identity captured by sidebar response and steering callbacks.
struct AIActiveChatRequest {
    let request: UUID
    let assistant: UUID
    let conversation: UUID
    let provider: AICLIType
}
