import Foundation

/// Runtime boundary: implementations own process lifetime, streaming and cancellation.
@MainActor
protocol AIRequestExecuting {
    func sendPrompt(_ prompt: String, cliType: AICLIType, workingDirectory: URL?,
                    sessionId: String?, allowsWorkspaceEdits: Bool, options: AIRequestOptions,
                    streamHandler: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult
    func steer(_ instruction: String) async throws
    func cancel()
}


extension AIRequestExecuting {
    func steer(_ instruction: String) async throws { throw AISteeringError.unsupported }
}

enum AISteeringError: LocalizedError {
    case unsupported, unavailable
    var errorDescription: String? {
        L10n.get(self == .unsupported ? "ai.queue.steerUnsupported" : "ai.queue.steerUnavailable")
    }
}
