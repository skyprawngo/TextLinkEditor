import Foundation

// Compiled with the production parser, process manager, models and history manager.
// Fixture executables emit JSON only; no installed AI CLI or network is used.
final class UserSettings {
    static let shared = UserSettings()
    var path: URL?
    var aiAssistantEnabled = false
    var aiAssistantCLIType = ""
    var aiTerminalMode = false
    func setAICLIPath(_ url: URL) -> Bool { path = url; return true }
    func getAICLIPath() -> URL? { path }
}
struct TestEditorTab { var url: URL; var title: String }
@MainActor final class EditorTabManager {
    static let shared = EditorTabManager()
    var selectedTab: TestEditorTab?
    func flushEditor() {}
    func prepareForAIWorkspaceEdit(project: URL) throws {}
    func validateAIApplication(project: URL) throws {}
    func collaborationDrafts(project: URL) -> [String: String] { [:] }
    func isModified(url: URL) -> Bool { false }
    func getCachedContent(for url: URL) -> String? { nil }
}
final class CLIInstaller {
    static let shared = CLIInstaller()
    func openInstallPage(for type: AICLIType) {}
}
enum L10n { static func get(_ key: String) -> String { key == "ai.chat.documentPrompt" ? "Document: {name}\n{document}\nQuestion: {question}" : key } }

@main struct AIRegression {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live-steering") {
            guard let path = await CLIDetector.shared.resolvedPath(for: .chatgpt) else { fatalError("Codex unavailable") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkSteer-Live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let turn = CodexActiveTurn()
            let task = Task { try await turn.run(path: path,
                prompt: "This is an isolated UI integration test. First run the shell command sleep 6, then reply ONLY FIRST. Do not read or write files.",
                directory: directory, sessionID: nil, options: .init(), allowsWorkspaceEdits: false, compactLimit: nil) { _ in } }
            try await Task.sleep(for: .seconds(3))
            do { try await turn.steer("Change the final answer to ONLY STEERING_CONFIRMED. Continue the same turn.") }
            catch { turn.cancel(); _ = try? await task.value; throw error }
            let result = try await task.value
            precondition(result.response.contains("STEERING_CONFIRMED"), "live response did not reflect steering")
            print("PASS live Codex same-turn steering reflected in final answer")
            return
        }
        if CommandLine.arguments.contains("--live-collaboration") {
            let project = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkEditor-Collaboration-Live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("설정"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: project) }
            try "민수는 범인을 모른다. 범인은 도윤이다.".write(to: project.appendingPathComponent("설정/인물.md"), atomically: true, encoding: .utf8)
            try "민수는 말했다. 나는 범인을 모른다.".write(to: project.appendingPathComponent("원고.md"), atomically: true, encoding: .utf8)
            let store = CollaborationStore(project: project)
            try store.enable()
            let original = try store.snapshot()
            let task = try store.enqueue(origin: "comment", instruction: "민수는 처음부터 도윤이 범인임을 알고 있고 숨기거나 거짓말하지 않는다고 확정한다. 설정/인물.md는 정확히 '민수는 처음부터 도윤이 범인임을 안다.'로, 원고.md는 정확히 '민수는 말했다. 도윤이 범인임을 처음부터 알았다.'로 수정하라. 확정 설정을 원문과 연결해 색인하라. 줄바꿈은 추가하지 마라.")
            _ = try await CollaborationEngine(store: store, executor: CLIProcessManager()).execute(taskID: task, provider: .chatgpt, options: .init())
            let after = try store.snapshot()
            precondition(after["설정/인물.md"] == "민수는 처음부터 도윤이 범인임을 안다.")
            precondition(after["원고.md"] == "민수는 말했다. 도윤이 범인임을 처음부터 알았다.")
            let completed = try store.load().tasks.first?.phase == .completed
            precondition(completed)
            try CollaborationApplier(store: store).undo(taskID: task)
            let restored = try store.snapshot()
            precondition(restored == original)
            print("PASS existing OAuth: live isolated collaboration, two document apply, journal and undo")
            return
        }
        if CommandLine.arguments.contains("--live-workspace") {
            let project = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkEditor-Live-" + UUID().uuidString + ".weaveproj")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: project) }
            let file = project.appendingPathComponent("draft.md")
            try "첫 번째 행\n2".write(to: file, atomically: true, encoding: .utf8)
            let id = UUID(), before = try AIWorkspaceEdits.prepare(id: UUID(), project: project)
            let result = try await CLIProcessManager().sendPrompt("Edit only draft.md in this temporary QA project. Read it, replace its last line 2 with 새로운문장, save preserving the first line and no trailing newline, then read the saved file to verify. Do not change any other file. Reply briefly.", cliType: .chatgpt, workingDirectory: project, allowsWorkspaceEdits: true) { _ in }
            try AIWorkspaceEdits.finish(id: id, before: before, project: project)
            let actual = try String(contentsOf: file, encoding: .utf8)
            guard actual == "첫 번째 행\n새로운문장",
                  AIWorkspaceEdits.load(id: id, project: project)?.changes.first?.after == actual else {
                fatalError("Live workspace edit failed: " + result.response)
            }
            print("PASS live Codex workspace edit, exact saved bytes, persisted before/after comparison")
            return
        }
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        let text = "한글🙂é\n日本語"
        let event: [String: Any] = ["type": "stream_event", "event": ["delta": ["type": "text_delta", "text": text]]]
        let result: [String: Any] = ["type": "result", "subtype": "success", "result": text, "session_id": "session-1"]
        let bytes = try JSONSerialization.data(withJSONObject: event) + Data([10]) + JSONSerialization.data(withJSONObject: result) + Data([10])
        var parser = CLIJSONStream()
        var streamed = ""
        for byte in bytes { streamed += parser.append(Data([byte])).joined() }
        parser.finish()
        expect(streamed == text, "UTF-8 split at every byte must survive")
        expect(parser.response == text && parser.completed && !parser.failed, "Explicit final result")
        expect(parser.sessionId == "session-1", "Session ID is structured")
        var partial = CLIJSONStream()
        _ = partial.append(try JSONSerialization.data(withJSONObject: event))
        partial.finish()
        expect(!partial.completed, "Silence/partial data must not complete a response")
        var codex = CLIJSONStream()
        _ = codex.append(Data("{\"type\":\"thread.started\",\"thread_id\":\"thread-1\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hello\"}}\n{\"type\":\"turn.completed\"}\n".utf8))
        expect(codex.completed && codex.response == "hello" && codex.sessionId == "thread-1", "Codex events")
        var failed = CLIJSONStream()
        _ = failed.append(Data("{\"type\":\"turn.failed\"}\n".utf8))
        expect(failed.failed, "Failed event is not assistant success")
        expect(AIPromptTemplateManager.render("{{question}} {{answer}}", values: ["question": "{{answer}}", "answer": "real"]) == "{{answer}} real", "Inserted text cannot replace another placeholder")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkEditorAIRegression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await checkChatDrafts(in: folder)
        try await checkQueue(in: folder)
        try await checkActiveTurn(in: folder)
        try await checkSteeringViewModel(in: folder)
        try checkHistoryRepository(in: folder)
        try await checkCollaboration(in: folder)
        let a = folder.appendingPathComponent("A.weaveproj")
        let model = AIModelOption.parse(["model": "fixture-model", "displayName": "Fixture", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]])!
        expect(model.efforts == ["low", "high"], "model catalog retains supported efforts")
        expect(AIModelOption.parse(["model": "hidden", "hidden": true]) == nil, "hidden models excluded")
        let options = AIRequestOptions(model: model.id, effort: "high")
        expect(options.arguments(for: .chatgpt) == ["--model", "fixture-model", "-c", "model_reasoning_effort=\"high\""], "Codex model and effort use explicit CLI arguments")
        expect(options.arguments(for: .claude) == ["--model", "fixture-model", "--effort", "high"], "Claude model and effort use provider flags")
        let usage = AIContextUsage.parse(["type": "turn.completed", "usage": ["input_tokens": 1200, "cached_input_tokens": 800, "output_tokens": 50]])!
        expect(usage.inputTokens == 1200 && usage.cachedTokens == 800 && usage.contextWindow == nil, "Codex totals do not double count cache or invent capacity")
        let claudeUsage = AIContextUsage.parse(["type": "result", "usage": ["input_tokens": 100, "cache_read_input_tokens": 800, "cache_creation_input_tokens": 100, "output_tokens": 50], "modelUsage": ["fixture": ["contextWindow": 200000]]])!
        expect(claudeUsage.inputTokens == 1000 && claudeUsage.contextWindow == 200000, "Claude usage includes cache and reported capacity")
        let usageMessage = AIMessage(role: .assistant, content: "answer", usage: usage)
        let decodedUsageMessage = try JSONDecoder().decode(AIMessage.self, from: JSONEncoder().encode(usageMessage))
        expect(decodedUsageMessage == usageMessage, "usage survives history encoding")
        expect(usage.compactionProgress == nil, "billing totals never become context progress")
        let legacyUsage = try JSONDecoder().decode(AIContextUsage.self, from: Data("{\"inputTokens\":12,\"cachedTokens\":0,\"outputTokens\":3}".utf8))
        expect(legacyUsage.compactionProgress == nil, "legacy records retain unknown context")
        let meterRoot = folder.appendingPathComponent("meter")
        let meterID = UUID().uuidString
        let meterSessions = meterRoot.appendingPathComponent("sessions/2026/09/20")
        try FileManager.default.createDirectory(at: meterSessions, withIntermediateDirectories: true)
        try Data("{\"models\":[{\"slug\":\"fixture\",\"context_window\":100000,\"effective_context_window_percent\":95}]}".utf8)
            .write(to: meterRoot.appendingPathComponent("models_cache.json"))
        let limit = CodexContextMeter.threshold(model: "fixture", root: meterRoot)
        expect(limit == 85500 && CodexContextMeter.threshold(model: "unknown", root: meterRoot) == nil, "threshold uses only known model metadata")
        let tokenEvent = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":999999},\"last_token_usage\":{\"total_tokens\":42750},\"model_context_window\":95000}}}".utf8)
        let meterFile = meterSessions.appendingPathComponent("rollout-test-\(meterID).jsonl")
        try tokenEvent.write(to: meterFile)
        let measured = CodexContextMeter.read(sessionID: meterID, root: meterRoot, limit: limit, usage: usage)!
        expect(measured.compactionProgress == 0.5 && measured.inputTokens == 1200, "context progress remains separate from billing")
        expect(CodexContextMeter.latestObservation(lines: [tokenEvent, Data("{\"type\":\"compacted\"}".utf8)]) == nil, "compaction invalidates stale counts")
        let reducedEvent = Data(String(decoding: tokenEvent, as: UTF8.self).replacingOccurrences(of: "42750", with: "4000").utf8)
        expect(CodexContextMeter.latestObservation(lines: [tokenEvent, Data("{\"type\":\"compacted\"}".utf8), reducedEvent])?.tokens == 4000, "post-compaction count replaces high-water mark")
        expect(CodexContextMeter.read(sessionID: "../../outside", root: meterRoot, limit: limit, usage: usage) == usage, "invalid session paths rejected")
        let decodedMeter = try JSONDecoder().decode(AIContextUsage.self, from: JSONEncoder().encode(measured))
        expect(decodedMeter == measured, "context observation persists")
        let b = folder.appendingPathComponent("B.weaveproj")
        let root = UUID()
        let user = AIMessage(id: root, role: .user, content: "first", conversationId: root)
        let answer = AIMessage(role: .assistant, content: "answer", conversationId: root)
        let second = AIMessage(role: .user, content: "followup", conversationId: root)
        let response = AIMessage(role: .assistant, content: "followup answer", conversationId: root)
        try ChatHistoryManager.shared.saveState(messages: [user, answer, second, response], taggedIds: [root], sessionIds: [root: "session"], cliType: "claude", to: a)
        let bUser = AIMessage(role: .user, content: "B question")
        try ChatHistoryManager.shared.saveState(messages: [bUser], taggedIds: [], sessionIds: [:], cliType: "claude", to: b)
        let loaded = ChatHistoryManager.shared.loadSession(from: a)!
        expect(loaded.messages.count == 4 && loaded.messages.last?.content == response.content, "All turns roundtrip")
        expect(loaded.messages.allSatisfy { $0.conversationId == root }, "Conversation identity persists")
        expect(ChatHistoryManager.shared.loadSession(from: b)?.messages.count == 1, "Other project untouched")
        let old = "{\"projectPath\":\"old\",\"cliType\":\"claude\",\"cardIds\":[],\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let oldMetadata = try decoder.decode(ChatSessionMetadata.self, from: Data(old.utf8))
        expect(oldMetadata.cardSessionIds.isEmpty, "Missing historical session map migrates")

        let executable = folder.appendingPathComponent("claude")
        UserSettings.shared.path = executable
        func fixture(_ body: String) throws {
            let adapted = body.replacingOccurrences(of: "> arguments.log", with: "> '" + folder.path + "/arguments.log'")
                .replacingOccurrences(of: "> prompt.log", with: "> '" + folder.path + "/prompt.log'")
            try ("#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + folder.path + "/arguments.log'\n" + adapted).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try fixture("cat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"fixture response\",\"session_id\":\"fixture\"}'\n")
        let manager = CLIProcessManager()
        let prompt = "apostrophe ' $(never execute) 한글"
        let first = try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in }
        expect(first.response == "fixture response", "Direct process with stdin works")
        try fixture("cat >/dev/null\nexit 7\n")
        do {
            _ = try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in }
            preconditionFailure("Nonzero exit must throw")
        } catch { assertions += 1 }
        try fixture("exit 9\n")
        do {
            _ = try await manager.sendPrompt(String(repeating: "x", count: 500_000), cliType: .claude, workingDirectory: folder) { _ in }
            preconditionFailure("Early exit must throw without killing the host via SIGPIPE")
        } catch CLIProcessManager.CLIError.failed(9) { assertions += 1 }
        try fixture("cat >/dev/null\nprintf '%s\\n' 'unknown option --safe-mode' >&2\nexit 2\n")
        do {
            _ = try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in }
            preconditionFailure("Old CLI must report incompatible")
        } catch CLIProcessManager.CLIError.incompatibleCLI { assertions += 1 }
        try fixture("cat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in\"}'\nexit 1\n")
        do {
            _ = try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in }
            preconditionFailure("Authentication must report login required")
        } catch CLIProcessManager.CLIError.authentication { assertions += 1 }
        try fixture("cat >/dev/null\nexec /bin/sleep 30\n")
        let task = Task { try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancellation must throw") }
        catch is CancellationError { assertions += 1 }
        try fixture("cat >/dev/null\n/bin/sleep 30 &\necho $! > child.pid\nwait\n")
        let childTask = Task { try await manager.sendPrompt(prompt, cliType: .claude, workingDirectory: folder) { _ in } }
        let childFile = folder.appendingPathComponent("child.pid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let childPID = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        childTask.cancel()
        do { _ = try await childTask.value; preconditionFailure("Child-group cancellation must throw") }
        catch is CancellationError { assertions += 1 }
        for _ in 0..<100 where kill(childPID, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        expect(kill(childPID, 0) == -1 && errno == ESRCH, "Cancellation terminates inherited CLI child processes")
        try fixture("cat >/dev/null\nexec /bin/sleep 30\n")
        // View-model regression: an old request cannot attach its result to the new project.
        let suite = "TextlinkEditor.ModelPreferencesTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = AIAssistantViewModel(modelDefaults: defaults)
        expect(vm.models(for: .chatgpt).contains { $0.id == "gpt-6-astra" }, "Astra remains explicitly selectable with an older catalog")
        let catalogAstra = AIModelOption(id: "gpt-6-astra", name: "Catalog Astra", efforts: ["medium", "ultra"], defaultEffort: "medium")
        vm.availableModels = [catalogAstra]
        expect(vm.models(for: .chatgpt).filter { $0.id == "gpt-6-astra" } == [catalogAstra], "live Astra metadata takes priority without duplicates")
        vm.availableModels = [model]
        vm.modelSelections = ["chatgpt": model.id]
        vm.modelPreferences.effortSelections = ["chatgpt": "ultra"]
        expect(vm.requestOptions(for: .chatgpt).effort == "low", "unsupported saved effort is never forwarded")
        vm.modelPreferences.effortSelections["chatgpt"] = "high"
        expect(vm.requestOptions(for: .chatgpt).model == model.id && vm.requestOptions(for: .chatgpt).effort == "high", "selected model and supported effort captured together")
        expect(vm.requestOptions(for: .claude).model == "sonnet", "provider selections remain independent")
        vm.selectModel("gpt-6-astra", for: .chatgpt)
        expect(vm.requestOptions(for: .chatgpt).effort == "high", "switching model preserves compatible last effort")
        vm.selectEffort("max", for: .chatgpt)
        let restored = AIAssistantViewModel(modelDefaults: defaults)
        expect(restored.requestOptions(for: .chatgpt).model == "gpt-6-astra" && restored.requestOptions(for: .chatgpt).effort == "max", "last chosen model and effort survive recreation")
        vm.selectModel(model.id, for: .chatgpt)
        expect(vm.requestOptions(for: .chatgpt).effort == "low", "unsupported last effort becomes a supported concrete value")
        vm.selectEffort("", for: .chatgpt)
        expect(vm.requestOptions(for: .chatgpt).effort == "low", "empty default step cannot overwrite saved effort")
        vm.selectModel("sonnet", for: .claude)
        vm.selectEffort("high", for: .claude)
        vm.selectModel("opus", for: .claude, category: .inlineEdit)
        vm.selectEffort("low", for: .claude, category: .inlineEdit)
        let separate = AIAssistantViewModel(modelDefaults: defaults)
        expect(separate.requestOptions(for: .claude).model == "sonnet" && separate.requestOptions(for: .claude).effort == "high", "sidebar preferences persist separately")
        expect(separate.requestOptions(for: .claude, category: .inlineEdit).model == "opus" && separate.requestOptions(for: .claude, category: .inlineEdit).effort == "low", "inline preferences persist separately")
        vm.selectModel("haiku", for: .claude, category: .commitMessage)
        let commitPreferences = AIAssistantViewModel(modelDefaults: defaults)
        expect(commitPreferences.requestOptions(for: .claude, category: .commitMessage).model == "haiku" && commitPreferences.requestOptions(for: .claude).model == "sonnet", "commit model persists independently of chat")
        let decodedCommitMessage = try AICommitMessage.decode(#"{"message":" Add worldbuilding "}"#)
        expect(decodedCommitMessage == "Add worldbuilding", "generated commit message trims whitespace")
        do { _ = try AICommitMessage.decode("{\"message\":\"  \"}"); preconditionFailure("empty commit message accepted") } catch {}
        expect(true, "empty generated commit message rejected")
        vm.modelSelections = [:]
        vm.modelPreferences.effortSelections = [:]
        vm.completeConnection(.claude)
        vm.setProject(a)
        let messageCountBeforeMode = vm.messages.count
        vm.inputText = "/계획"
        vm.sendMessage()
        expect(vm.chatMode == .plan && !vm.isProcessing && vm.messages.count == messageCountBeforeMode, "mode-only command changes mode without inference or history turn")
        expect(AIChatMode.parse("/계획 세계관 구상")?.body == "세계관 구상" && AIChatMode.parse("/plan")?.mode == .plan, "Korean and English slash commands parse")
        expect(AIChatMode.parse("문장 속 /계획")?.body == "문장 속" && AIChatMode.parse("/계획서") == nil, "tags work after text without matching longer words")
        let suffixTag = AIChatMode.parse("`지금까지 합의한 내용을 설정/세계관.md로 정리해 줘`/작성")
        expect(suffixTag?.mode == .write && suffixTag?.body == "`지금까지 합의한 내용을 설정/세계관.md로 정리해 줘`", "attached suffix tag preserves quoted Korean body")
        expect(AIChatMode.parse("던전/계획 규칙을\n구상해 줘")?.body == "던전 규칙을\n구상해 줘", "middle tag preserves multiline body")
        expect(AIChatMode.parse("/계획 내용을 정리해 줘/작성")?.mode == .write && AIChatMode.parse("/계획 내용을 정리해 줘/작성")?.body == "내용을 정리해 줘", "last tag wins and all mode tags are removed")
        expect(AIChatMode.parse("설정/작성.md https://example.com/plan") == nil, "file names and URL paths are not mode tags")
        expect(AIChatMode.removingTagsForSelection("앞의 본문/작") == "앞의 본문" && AIChatMode.completionRange("앞의 본문/") != nil, "suffix tag picker preserves draft text")
        vm.inputText = "slow A request"
        vm.sendMessage()
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.setProject(b)
        try await Task.sleep(nanoseconds: 200_000_000)
        expect(vm.messages.count == 1 && vm.messages[0].id == bUser.id, "Project switch drops old callbacks")
        expect(ChatHistoryManager.shared.loadSession(from: a)?.messages.last?.outcome == "cancelled", "Cancelled turn belongs to originating project")
        expect(ChatHistoryManager.shared.loadSession(from: b)?.messages.count == 1, "Old answer cannot overwrite B last card")
        func conversationFixture() throws {
            let proposal = "{\"summary\":\"new response\",\"edits\":[],\"questions\":[],\"facts\":[]}"
            func event(_ text: String) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "result": text, "session_id": "new"], options: [.sortedKeys]), as: UTF8.self)
            }
            try fixture("printf '%s\\n' \"$@\" > arguments.log\ncat > prompt.log\nif grep -q 'Return ONLY one JSON object' '\(folder.path)/prompt.log'; then\nprintf '%s\\n' '\(try event(proposal))'\nelse\nprintf '%s\\n' '\(try event("new response"))'\nfi\n")
        }
        try conversationFixture()
        vm.inputText = "B followup"
        vm.sendMessage(continueFromCardId: bUser.id)
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        if vm.messages.last?.content != "new response" { FileHandle.standardError.write(Data(("Fixture failure: " + (vm.errorMessage ?? "none") + " content=" + (vm.messages.last?.content ?? "nil") + "\n").utf8)) }
        expect(vm.messages.last?.content == "new response" && vm.selectedCardId == bUser.id, "Followup stays in selected conversation")
        expect(vm.messages.last?.conversationId == bUser.id, "Followup identity remains persisted")
        vm.inputText = "던전의 규칙을 함께 구상하자/계획"
        vm.sendMessage()
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        let planningPrompt = try String(contentsOf: folder.appendingPathComponent("prompt.log"), encoding: .utf8)
        expect(planningPrompt.contains("Current mode: planning") && planningPrompt.contains("B followup"), "planning retains completed conversation and explicit read-only mode")
        expect(vm.messages.last?.content == "new response", "planning returns prose without proposal parsing")
        expect(vm.messages.dropLast().last?.content == "던전의 규칙을 함께 구상하자" && vm.messages.dropLast().last?.chatMode == "plan", "suffix command persists as message tag instead of body text")
        expect(vm.chatMode == .conversation, "sent planning tag is consumed for the next message")
        let draftTag = AIChatMode.extractDraftTag("앞 /작성 뒤", selection: NSRange(location: 5, length: 0))!
        expect(draftTag.mode == .write && draftTag.body == "앞  뒤" && draftTag.selection.location == 2,
               "typed command becomes tag while preserving surrounding spaces and caret")
        vm.setProject(a)
        vm.setProject(b)
        expect(vm.selectedCardId == bUser.id, "Reopening project restores its latest normal chat")
        expect(vm.chatMode == .conversation, "reopening history does not reuse a previous command")
        vm.inputText = "resume from project files"
        vm.sendMessage()
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        let resumedArguments = try String(contentsOf: folder.appendingPathComponent("arguments.log"), encoding: .utf8)
        let resumedPrompt = try String(contentsOf: folder.appendingPathComponent("prompt.log"), encoding: .utf8)
        expect(resumedArguments.contains("--resume\nnew") && resumedArguments.contains("Read,Glob,Grep"), "Restored chat resumes provider session with project reading tools")
        expect(resumedPrompt.contains("TextlinkCollaboration-") && !resumedPrompt.contains(b.path), "Chat runs against isolated copy with no live root in prompt")
        expect(vm.resumableSession(for: bUser.id, provider: .chatgpt) == nil, "Provider sessions cannot be mixed")
        try fixture("cat >/dev/null\nexit 7\n")
        vm.inputText = "retry project question"
        vm.sendMessage()
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(vm.resumableSession(for: bUser.id, provider: .claude) == nil, "Failed session is detached")
        try conversationFixture()
        vm.sendMessage()
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        let retryArguments = try String(contentsOf: folder.appendingPathComponent("arguments.log"), encoding: .utf8)
        let retryPrompt = try String(contentsOf: folder.appendingPathComponent("prompt.log"), encoding: .utf8)
        expect(!retryArguments.contains("--resume") && retryPrompt.contains("B followup") && retryPrompt.contains("new response"), "User retry reconstructs completed conversation when session is unavailable")
        vm.selectedCardId = nil
        let manuscript = b.appendingPathComponent("manuscript.md")
        var fullText = "alpha\n한글 😀 원고 전체"
        try fullText.write(to: manuscript, atomically: true, encoding: .utf8)
        EditorTabManager.shared.selectedTab = TestEditorTab(url: manuscript, title: "manuscript.md")
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("editorWillPerformFileOperation"), object: nil, queue: .main) { note in
            (note.userInfo?["captureSelection"] as? (String, NSRange) -> Void)?(fullText, NSRange(location: 0, length: 5))
            if let apply = note.userInfo?["applyRevision"] as? (String, NSRange) -> String?, let updated = apply(fullText, NSRange(location: 0, length: 5)) { fullText = updated }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        vm.includeCurrentDocument = true
        vm.inputText = "whole manuscript review"
        vm.sendMessage()
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        let responseID = vm.messages.last!.id
        let revision = ManuscriptRevisionBridge.load(id: responseID, project: b)!
        expect(revision.target == fullText && revision.selectionLength == fullText.utf16.count, "whole prompt and apply scope match despite selected text")
        let metadata = b.appendingPathComponent(".\(b.deletingPathExtension().lastPathComponent).weavedata")
        let manifest = try JSONDecoder().decode(AIContextManifest.self, from: Data(contentsOf: metadata.appendingPathComponent("ai-context/\(responseID.uuidString).json")))
        expect(manifest.text.contains(fullText) && manifest.entries.contains { $0.kind == .manuscript }, "manifest includes actual submitted manuscript")
        let sidebarConversation = vm.selectedCardId
        vm.inputText = "keep sidebar draft"
        let inlineConversation = UUID()
        vm.sendMessage(continueFromCardId: inlineConversation, inlineInput: "captured passage question")
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(vm.inputText == "keep sidebar draft" && vm.selectedCardId == sidebarConversation, "inline request preserves sidebar draft and selected conversation")
        expect(vm.messages.last?.conversationId == inlineConversation && vm.messages.last?.content == "new response", "inline response uses its own persisted conversation")
        let inlineID = vm.messages.last!.id
        let inlineManifest = try JSONDecoder().decode(AIContextManifest.self, from: Data(contentsOf: metadata.appendingPathComponent("ai-context/\(inlineID.uuidString).json")))
        expect(!inlineManifest.entries.contains { $0.kind == .manuscript }, "inline request does not silently attach entire manuscript")
        vm.sendMessage(continueFromCardId: inlineConversation, inlineInput: "follow up inline")
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(vm.messages.last?.conversationId == inlineConversation, "inline followup stays in same conversation")
        let editBase = fullText
        let edit = ManuscriptRevision(id: UUID(), relativePath: "manuscript.md", original: editBase, selectionLocation: 0, selectionLength: 5)
        let replacementJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["replacement":"검정"]), as: UTF8.self)
        let editJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["type":"result", "subtype":"success", "result":replacementJSON]), as: UTF8.self)
        try fixture("cat >/dev/null\nprintf '%s\\n' '" + editJSON + "'\n")
        vm.selectModel("sonnet", for: .claude)
        vm.selectEffort("high", for: .claude)
        vm.selectModel("opus", for: .claude, category: .inlineEdit)
        vm.selectEffort("low", for: .claude, category: .inlineEdit)
        vm.errorMessage = "existing sidebar error"
        vm.sendMessage(continueFromCardId: sidebarConversation, inlineInput: "검정으로 수정", inlineRevision: edit)
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(fullText == (editBase as NSString).replacingCharacters(in: NSRange(location: 0, length: 5), with: "검정"), "inline edit executes replacement on captured range")
        expect(vm.messages.last?.model == "opus" && vm.messages.last?.reasoningEffort == "low" && vm.messages.last?.provider == "claude", "inline dispatch snapshots independent model and effort")
        let savedIndex = try JSONAIHistoryRepository().load(from: b)!.metadata
        let inlineRecord = savedIndex.conversations.first { $0.id == vm.messages.last?.conversationId }
        expect(savedIndex.schemaVersion == 2 && inlineRecord?.category == .inlineEdit && inlineRecord?.requestIds == [vm.messages.last!.id], "history indexes category, conversation and request IDs")
        expect(savedIndex.conversations.contains { $0.category == .chat }, "normal and inline histories have separate category entries")
        expect(vm.messages.last?.kind == "inlineEdit" && vm.messages.last?.outcome == "completed", "inline edit records applied outcome separately")
        expect(ChatHistoryManager.shared.loadSession(from: b)?.messages.last?.kind == "inlineEdit", "inline category survives history persistence")
        let firstEditConversation = vm.messages.last!.conversationId
        let inlineArguments = try String(contentsOf: folder.appendingPathComponent("arguments.log"), encoding: .utf8)
        expect(!inlineArguments.contains("Read,Glob,Grep") && !inlineArguments.contains("--resume"), "Inline editing does not enable project tools or resume chat")
        expect(firstEditConversation != sidebarConversation, "inline edit always creates a new history conversation")
        expect(vm.selectedCardId == sidebarConversation && vm.inputText == "keep sidebar draft", "automatic edit does not display a new sidebar answer or replace its draft")
        expect(vm.errorMessage == "existing sidebar error", "inline success leaves sidebar errors unchanged")
        let beforeStale = vm.messages.count
        vm.sendMessage(inlineInput: "stale edit", inlineRevision: edit)
        expect(vm.messages.count == beforeStale && !vm.isProcessing, "stale inline target prevents dispatch")
        expect(vm.inlineErrorMessage != nil && vm.errorMessage == "existing sidebar error", "preflight error stays in inline input")
        fullText = editBase
        try fixture("cat >/dev/null\nprintf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"ordinary chat is not an edit\"}'\n")
        vm.sendMessage(inlineInput: "invalid result", inlineRevision: edit)
        while vm.isProcessing { try await Task.sleep(nanoseconds: 20_000_000) }
        expect(fullText == editBase && vm.messages.last?.outcome == "failed", "conversational response cannot overwrite manuscript")
        expect(vm.messages.last?.conversationId != firstEditConversation, "each inline edit has an independent history entry")
        expect(vm.selectedCardId == sidebarConversation && vm.inputText == "keep sidebar draft", "failed inline edit preserves sidebar conversation and draft")
        expect(vm.errorMessage == "existing sidebar error" && vm.inlineErrorMessage == nil, "accepted inline failure appears only in history")
        expect(vm.messages.last?.content.contains("ordinary chat is not an edit") == true, "failed edit retains original AI response in history")
        expect(ChatHistoryManager.shared.loadSession(from: b)?.messages.last?.content == vm.messages.last?.content, "failed AI response survives persistence")
        vm.setProject(a)
        vm.setProject(b)
        expect(vm.selectedCardId == inlineConversation, "Reopening ignores newer inline edits and selects latest normal conversation")
        let orphan = UUID()
        try AIContextSelection.shared.persist(manifest, requestID: orphan, projectURL: b)
        vm.clearHistory()
        let artifactIDs = try AIContextSelection.shared.savedRequestIDs(projectURL: b)
        expect(artifactIDs.isEmpty, "clear history removes orphan and linked artifacts")
        let c = folder.appendingPathComponent("C")
        try FileManager.default.createDirectory(at: c.appendingPathComponent(".C.weavedata"), withIntermediateDirectories: true)
        try Data("invalid directory".utf8).write(to: c.appendingPathComponent(".C.weavedata/ai-revisions"))
        EditorTabManager.shared.selectedTab = TestEditorTab(url: c.appendingPathComponent("draft.md"), title: "draft.md")
        vm.setProject(c); vm.includeCurrentDocument = true; vm.inputText = "failed artifact preparation"
        vm.sendMessage()
        expect(!vm.isProcessing && vm.messages.isEmpty, "artifact preparation failure prevents dispatch")
        let contextDirectory = c.appendingPathComponent(".C.weavedata/ai-context")
        let residual = FileManager.default.fileExists(atPath: contextDirectory.path)
            ? try FileManager.default.contentsOfDirectory(at: contextDirectory, includingPropertiesForKeys: nil) : []
        expect(residual.isEmpty, "failed revision preparation cleans already persisted manifest")
        let workspace = folder.appendingPathComponent("Workspace.weaveproj")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceManuscript = workspace.appendingPathComponent("draft.md")
        let removed = workspace.appendingPathComponent("removed.txt")
        try "first\n2".write(to: workspaceManuscript, atomically: true, encoding: .utf8)
        try "remove me".write(to: removed, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("outside.md"), withDestinationURL: executable)
        let editID = UUID(), before = try AIWorkspaceEdits.prepare(id: UUID(), project: workspace)
        expect(before.count == 2, "snapshot excludes symlinks and metadata")
        let codexExecutable = folder.appendingPathComponent("codex")
        UserSettings.shared.path = codexExecutable
        func codexFixture(_ body: String) throws {
            try ("#!/bin/sh\nprintf '%s\n' \"$@\" > arguments.log\ncat >/dev/null\n" + body).write(to: codexExecutable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexExecutable.path)
        }
        func tracked(_ id: UUID, _ before: [String: String]) throws -> AIWorkspaceTrackingExecutor {
            try AIContextSelection.shared.persist(AIContextManifest(entries: [], text: "fixture"), requestID: id, projectURL: workspace)
            return AIWorkspaceTrackingExecutor(base: manager, requestID: id, project: workspace, before: before) { error in
                preconditionFailure("workspace reconciliation failed: \(error)")
            }
        }
        try codexFixture("printf 'first\\n새로운문장' > draft.md\nprintf 'created' > new.md\nrm removed.txt\nprintf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Explanation, not workspaceManuscript text\"}}' '{\"type\":\"turn.completed\"}'\n")
        _ = try await tracked(editID, before).sendPrompt("edit", cliType: .chatgpt, workingDirectory: workspace, sessionId: nil, allowsWorkspaceEdits: true, options: options) { _ in }
        let arguments = try String(contentsOf: workspace.appendingPathComponent("arguments.log"), encoding: .utf8)
        expect(arguments.contains("exec\n-c\ncli_auth_credentials_store=\"keyring\"\n"), "exec receives existing OAuth keyring overrides in subcommand scope")
        expect(arguments.contains("fixture-model") && arguments.contains("model_reasoning_effort=\"high\""), "selected model and effort reach spawned process")
        expect(arguments.contains("workspace-write") && arguments.contains(workspace.path) && !arguments.contains("danger-full-access"), "normal Codex explicitly bounds workspace writing")
        let edits = AIWorkspaceEdits.load(id: editID, project: workspace)!
        expect(edits.changes.count == 3, "created, deleted and edited files recorded")
        let changed = edits.changes.first { $0.relativePath == "draft.md" }!
        expect(changed.before == "first\n2" && changed.after == "first\n새로운문장", "comparison uses disk revisions, not response prose")
        expect(edits.changes.first { $0.relativePath == "removed.txt" }?.after == nil, "deleted file retains original")
        expect(edits.changes.first { $0.relativePath == "new.md" }?.before == nil, "created file retains absent baseline")
        try codexFixture("printf '%s\\n' '{\"type\":\"turn.completed\"}'\n")
        let codexRoot = UUID()
        let codexUser = AIMessage(id: codexRoot, role: .user, content: "project memory", conversationId: codexRoot, provider: "chatgpt")
        let codexAnswer = AIMessage(role: .assistant, content: "remembered", conversationId: codexRoot, outcome: "completed", provider: "chatgpt")
        try ChatHistoryManager.shared.saveState(messages: [codexUser, codexAnswer], taggedIds: [], sessionIds: [codexRoot: "codex-project-session"], cliType: "chatgpt", to: workspace)
        let restoredCodex = AIAssistantViewModel()
        restoredCodex.setProject(workspace)
        restoredCodex.completeConnection(.chatgpt)
        expect(restoredCodex.selectedCardId == codexRoot, "New view model restores Codex project conversation")
        let savedCodexSession = restoredCodex.resumableSession(for: codexRoot, provider: .chatgpt)
        expect(savedCodexSession == "codex-project-session", "Codex session persists across view model restart")
        _ = try await manager.sendPrompt("resume", cliType: .chatgpt, workingDirectory: workspace, sessionId: savedCodexSession, allowsWorkspaceEdits: true) { _ in }
        let resumedCodexArguments = try String(contentsOf: workspace.appendingPathComponent("arguments.log"), encoding: .utf8)
        expect(resumedCodexArguments.contains("resume\ncodex-project-session\n-") && resumedCodexArguments.contains("--cd\n" + workspace.path), "Codex uses explicit saved session and current project root")
        restoredCodex.setProject(b)
        expect(restoredCodex.resumableSession(for: codexRoot, provider: .chatgpt) == nil, "Project switch cannot reuse another project's Codex session")
        _ = try await manager.sendPrompt("inline", cliType: .chatgpt, workingDirectory: workspace) { _ in }
        expect(try! String(contentsOf: workspace.appendingPathComponent("arguments.log"), encoding: .utf8).contains("read-only"), "inline/default CLI remains read-only")
        let failedID = UUID(), failedBefore = try AIWorkspaceEdits.snapshot(project: workspace)
        try codexFixture("printf 'partial' > draft.md\nexit 7\n")
        do { _ = try await tracked(failedID, failedBefore).sendPrompt("fail after write", cliType: .chatgpt, workingDirectory: workspace, sessionId: nil, allowsWorkspaceEdits: true, options: .init()) { _ in }; preconditionFailure("expected failure") } catch {}
        expect(AIWorkspaceEdits.load(id: failedID, project: workspace)?.changes.first?.after == "partial", "partial writes remain comparable after process failure")
        let cancelledID = UUID(), cancelledBefore = try AIWorkspaceEdits.snapshot(project: workspace)
        try codexFixture("printf 'cancelled write' > draft.md\nexec /bin/sleep 30\n")
        let pendingEdit = Task { try await tracked(cancelledID, cancelledBefore).sendPrompt("cancel after write", cliType: .chatgpt, workingDirectory: workspace, sessionId: nil, allowsWorkspaceEdits: true, options: .init()) { _ in } }
        for _ in 0..<100 {
            if (try? String(contentsOf: workspaceManuscript, encoding: .utf8)) == "cancelled write" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        pendingEdit.cancel()
        do { _ = try await pendingEdit.value; preconditionFailure("expected cancellation") } catch {}
        expect(AIWorkspaceEdits.load(id: cancelledID, project: workspace)?.changes.first?.after == "cancelled write", "partial writes remain comparable after cancellation")
        try ManuscriptRevisionBridge.remove(id: editID, project: workspace)
        expect(!AIWorkspaceEdits.exists(id: editID, project: workspace), "history cleanup removes actual revision records")
        vm.completeConnection(.claude)
        vm.selectModel("haiku", for: .claude, category: .commitMessage)
        UserSettings.shared.path = executable
        let commitEvent: [String: Any] = ["type": "result", "subtype": "success", "result": #"{"message":"Add dungeon setting"}"#]
        let commitEventText = String(decoding: try JSONSerialization.data(withJSONObject: commitEvent), as: UTF8.self)
        try fixture("cat > prompt.log\nprintf '%s\\n' '" + commitEventText + "'\n")
        let historyBeforeCommit = vm.messages
        let generatedCommit = try await vm.generateCommitMessage(patch: "+A dungeon floats in the sky.")
        let commitArgs = try String(contentsOf: folder.appendingPathComponent("arguments.log"), encoding: .utf8)
        expect(generatedCommit == "Add dungeon setting" && vm.messages == historyBeforeCommit, "commit generation uses common runtime without changing chat history")
        expect(commitArgs.contains("haiku") && !commitArgs.contains("--resume") && !commitArgs.contains("Read,Glob,Grep"), "commit generation uses separate model and independent tool-free request")
        print("AI regression passed: \(assertions) assertions (fixtures only)")
    }
}
