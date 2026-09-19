import Foundation

/// Owns one app-server turn. Steering always targets its exact thread AND turn;
/// completion, rejection and transport closure never silently start another turn.
@MainActor
final class CodexActiveTurn {
    private let rpc = CodexRPCConnection()
    private var threadID: String?
    private var turnID: String?
    private var completion: Result<CLIPromptResult, Error>?
    private var waiter: CheckedContinuation<CLIPromptResult, Error>?
    private var pendingSteers = 0
    private var steerWaiter: CheckedContinuation<Void, Never>?
    private var finalText = ""
    private var lastText = ""
    private var usage: AIContextUsage?
    private var stream: (@MainActor @Sendable (String) -> Void)?

    func run(path: String, prompt: String, directory: URL?, sessionID: String?,
             options: AIRequestOptions, allowsWorkspaceEdits: Bool,
             compactLimit: Int?, stream: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult {
        self.stream = stream
        rpc.onNotification = { [weak self] in self?.receive($0, $1) }
        rpc.onClose = { [weak self] in self?.complete(.failure(CodexRPCConnection.Failure.stopped)) }
        try rpc.start(path: path)
        defer { rpc.close() }
        _ = try await rpc.request("initialize", ["clientInfo": ["name": "textlinkeditor_chat", "version": "1.0"]])
        try rpc.notify("initialized")
        try Task.checkCancellation()
        var config: [String: Any] = ["project_doc_max_bytes": 0]
        if let compactLimit { config["model_auto_compact_token_limit"] = compactLimit }
        var params: [String: Any] = ["approvalPolicy": "never", "sandbox": allowsWorkspaceEdits ? "workspace-write" : "read-only", "config": config]
        if let directory { params["cwd"] = directory.path }
        if let model = options.model { params["model"] = model }
        if let sessionID { params["threadId"] = sessionID }
        let thread = try await rpc.request(sessionID == nil ? "thread/start" : "thread/resume", params)
        guard let id = (thread["thread"] as? [String: Any])?["id"] as? String else { throw CodexRPCConnection.Failure.protocolError }
        threadID = id
        var turn: [String: Any] = ["threadId": id, "input": Self.input(prompt)]
        if let effort = options.effort { turn["effort"] = effort }
        let started = try await rpc.request("turn/start", turn)
        guard let startedID = (started["turn"] as? [String: Any])?["id"] as? String else { throw CodexRPCConnection.Failure.protocolError }
        turnID = startedID
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.complete(.failure(CLIProcessManager.CLIError.timeout))
            self?.rpc.close()
        }
        defer { timeout.cancel() }
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let completion { return try completion.get() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        // A completion notification can precede the steer acknowledgement on stdout.
        // Keep the transport alive until acceptance/rejection has been delivered.
        if pendingSteers > 0 { await withCheckedContinuation { steerWaiter = $0 } }
        return result
    }

    func steer(_ instruction: String) async throws {
        guard completion == nil, let threadID, let turnID else { throw AISteeringError.unavailable }
        pendingSteers += 1
        defer {
            pendingSteers -= 1
            if pendingSteers == 0 { let waiting = steerWaiter; steerWaiter = nil; waiting?.resume() }
        }
        let result = try await rpc.request("turn/steer", ["threadId": threadID,
            "expectedTurnId": turnID, "input": Self.input(instruction)])
        guard result["turnId"] as? String == turnID else { throw AISteeringError.unavailable }
    }

    func cancel() {
        complete(.failure(CancellationError()))
        rpc.close()
    }

    private static func input(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "text_elements": []]]
    }

    private func receive(_ method: String, _ params: [String: Any]) {
        guard completion == nil, params["threadId"] as? String == threadID else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            turnID = turn["id"] as? String
        }
        if let eventTurn = params["turnId"] as? String, let turnID, eventTurn != turnID { return }
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String { stream?(delta) }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let text = item["text"] as? String {
            lastText = text
            if item["phase"] as? String == "final_answer" { finalText += text }
        }
        if method == "thread/tokenUsage/updated", let tokens = params["tokenUsage"] as? [String: Any],
           let total = tokens["total"] as? [String: Any] {
            usage = AIContextUsage(inputTokens: total["inputTokens"] as? Int ?? 0,
                cachedTokens: total["cachedInputTokens"] as? Int ?? 0,
                outputTokens: total["outputTokens"] as? Int ?? 0, contextWindow: tokens["modelContextWindow"] as? Int)
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any],
           turn["id"] as? String == turnID {
            guard turn["status"] as? String == "completed" else {
                complete(.failure(CLIProcessManager.CLIError.failed(1))); return
            }
            complete(.success(CLIPromptResult(response: finalText.isEmpty ? lastText : finalText, sessionId: threadID, usage: usage)))
        }
    }

    private func complete(_ result: Result<CLIPromptResult, Error>) {
        guard completion == nil else { return }
        completion = result
        let current = waiter; waiter = nil
        current?.resume(with: result)
    }
}
