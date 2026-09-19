import Foundation

/// Conversation and writing share validated proposals; planning uses a read-only copy.
@MainActor
final class AIWorkspaceProposalExecutor: AIRequestExecuting {
    let base: any AIRequestExecuting
    let requestID: UUID
    let project: URL
    init(base: any AIRequestExecuting, requestID: UUID, project: URL) {
        self.base = base; self.requestID = requestID; self.project = project
    }
    func sendPrompt(_ prompt: String, cliType: AICLIType, workingDirectory: URL?, sessionId: String?,
                    allowsWorkspaceEdits: Bool, options: AIRequestOptions,
                    streamHandler: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult {
        guard allowsWorkspaceEdits else {
            if options.readsProjectFiles {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkCollaboration-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let store = CollaborationStore(project: project)
                let structure = try store.populateReadCopy(at: temporary, contents: store.snapshot())
                let currentPrompt = prompt.replacingOccurrences(of: project.path, with: temporary.path)
                    + "\nCurrent read-only project copy: " + temporary.path
                    + "\nEarlier session paths and edit-output contracts are stale. Use this copy for reading only. Follow the current chat mode and reply in conversational prose."
                    + "\n" + structure
                return try await base.sendPrompt(currentPrompt, cliType: cliType, workingDirectory: temporary,
                    sessionId: sessionId, allowsWorkspaceEdits: false, options: options, streamHandler: streamHandler)
            }
            return try await base.sendPrompt(prompt, cliType: cliType, workingDirectory: workingDirectory,
                sessionId: sessionId, allowsWorkspaceEdits: false, options: options, streamHandler: streamHandler)
        }
        let store = CollaborationStore(project: project)
        if !(try store.load().enabled) { try store.enable() }
        try store.enqueue(origin: "conversation", instruction: prompt, id: requestID)
        do {
            let result = try await CollaborationEngine(store: store, executor: base, checkEditor: {
                try EditorTabManager.shared.validateAIApplication(project: self.project)
            }).execute(taskID: requestID, provider: cliType, options: options, sessionID: sessionId, stream: streamHandler)
            // Preserve existing chat comparison UI using only app-applied changes.
            let changes = try store.journals().filter { $0.taskID == requestID && $0.phase == "committed" }
                .flatMap(\.changes).map { AIWorkspaceChange(relativePath: $0.path, before: $0.before, after: $0.after) }
            guard !changes.isEmpty else { return result }
            let file = try ManuscriptRevisionBridge.safeStorage(project: project).appendingPathComponent(requestID.uuidString + "-workspace.json")
            try JSONEncoder().encode(AIWorkspaceRevision(id: requestID, changes: changes)).write(to: file, options: .atomic)
            return result
        } catch {
            try store.updateTask(requestID) {
                $0.phase = Task.isCancelled ? .cancelled : .review
                $0.error = error.localizedDescription
            }
            throw error
        }
    }
    func cancel() { base.cancel() }
}
