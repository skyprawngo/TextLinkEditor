import Foundation
import Darwin

struct CLIPromptResult {
    let response: String
    let sessionId: String?
    var usage: AIContextUsage? = nil
}

/// Each panel owns its runner. No process or callback is shared across projects/windows.
@MainActor
final class CLIProcessManager: AIRequestExecuting {
    private var runner: CLIRequestRunner?
    private var activeTurn: CodexActiveTurn?

    func sendPrompt(_ prompt: String, cliType: AICLIType, workingDirectory: URL?,
                    sessionId: String? = nil, allowsWorkspaceEdits: Bool = false, options: AIRequestOptions = .init(),
                    streamHandler: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult {
        guard runner == nil, activeTurn == nil else { throw CLIError.busy }
        guard let path = await CLIDetector.shared.resolvedPath(for: cliType) else {
            throw CLIError.notFound
        }
        try Task.checkCancellation()
        guard runner == nil, activeTurn == nil else { throw CLIError.busy }
        // stdin avoids shell interpretation, argv length limits, and prompt exposure in process listings.
        let arguments: [String]
        let contextRoot = LoreCodexEnvironment.directory
        let compactLimit = cliType == .chatgpt ? await Task.detached {
            CodexContextMeter.threshold(model: options.model, root: contextRoot)
        }.value : nil
        try Task.checkCancellation()
        guard runner == nil, activeTurn == nil else { throw CLIError.busy }
        if cliType == .chatgpt && options.allowsSteering {
            let current = CodexActiveTurn()
            activeTurn = current
            defer { if activeTurn === current { activeTurn = nil } }
            return try await withTaskCancellationHandler {
                var result = try await current.run(path: path, prompt: prompt, directory: workingDirectory,
                    sessionID: sessionId, options: options, allowsWorkspaceEdits: allowsWorkspaceEdits,
                    compactLimit: compactLimit, stream: streamHandler)
                let completed = result
                result.usage = await Task.detached {
                    CodexContextMeter.read(sessionID: completed.sessionId, root: contextRoot,
                        limit: compactLimit, usage: completed.usage)
                }.value
                return result
            } onCancel: { Task { @MainActor in current.cancel() } }
        }
        switch cliType {
        case .claude:
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--safe-mode", "--tools", options.readsProjectFiles ? "Read,Glob,Grep" : ""]
            if options.readsProjectFiles {
                args += ["--permission-mode", "dontAsk", "--allowedTools", "Read(./**),Glob,Grep"]
            }
            args += options.arguments(for: cliType)
            if let sessionId { args += ["--resume", sessionId] }
            arguments = args
        case .chatgpt:
            try LoreCodexEnvironment.prepare()
            // exec owns its config overrides. Top-level -c values are not
            // reliably propagated into exec's auth store by supported runtimes.
            var args = ["--ask-for-approval", "never", "exec"] + LoreCodexEnvironment.arguments + ["--json", "--sandbox", allowsWorkspaceEdits ? "workspace-write" : "read-only",
                        "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"]
            args += options.arguments(for: cliType)
            if let workingDirectory { args += ["--cd", workingDirectory.path] }
            if let compactLimit { args += ["-c", "model_auto_compact_token_limit=\(compactLimit)"] }
            if let sessionId { args += ["resume", sessionId] }
            args.append("-")
            arguments = args
        }
        let current = CLIRequestRunner(path: path, arguments: arguments, prompt: prompt,
                                       workingDirectory: workingDirectory, environment: cliType == .chatgpt ? LoreCodexEnvironment.environment() : nil, streamHandler: streamHandler)
        runner = current
        defer { if runner === current { runner = nil } }
        return try await withTaskCancellationHandler {
            var result = try await current.run()
            if cliType == .chatgpt {
                let completed = result
                result.usage = await Task.detached {
                    CodexContextMeter.read(sessionID: completed.sessionId, root: contextRoot,
                                           limit: compactLimit, usage: completed.usage)
                }.value
            }
            return result
        } onCancel: {
            current.cancel()
        }
    }

    func steer(_ instruction: String) async throws {
        guard let activeTurn else { throw AISteeringError.unavailable }
        try await activeTurn.steer(instruction)
    }

    func cancel() { runner?.cancel(); activeTurn?.cancel() }

    enum CLIError: LocalizedError {
        case notFound, unsupportedProvider, terminalUnavailable, busy, timeout, invalidOutput, authentication, incompatibleCLI, failed(Int32)
        var errorDescription: String? {
            switch self {
            case .notFound: return L10n.get("ai.error.cliNotFound")
            case .unsupportedProvider: return L10n.get("ai.error.unsupportedProvider")
            case .terminalUnavailable: return L10n.get("ai.error.terminalUnavailable")
            case .busy: return L10n.get("ai.error.busy")
            case .timeout: return L10n.get("ai.error.timeout")
            case .invalidOutput: return L10n.get("ai.error.invalidOutput")
            case .authentication: return L10n.get("ai.error.authentication")
            case .incompatibleCLI: return L10n.get("ai.error.incompatibleCLI")
            case .failed(let status): return L10n.get("ai.error.processFailed").replacingOccurrences(of: "{status}", with: String(status))
            }
        }
    }
}
