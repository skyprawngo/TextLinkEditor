import Foundation

@MainActor private final class QueueExecutor: AIRequestExecuting {
    var prompts: [String] = []
    var options: [AIRequestOptions] = []
    var pending: CheckedContinuation<CLIPromptResult, Error>?
    var steering: CheckedContinuation<Void, Error>?
    var instructions: [String] = []
    func steer(_ instruction: String) async throws {
        instructions.append(instruction)
        try await withCheckedThrowingContinuation { steering = $0 }
    }
    func acceptSteering() { let next = steering; steering = nil; next?.resume() }
    func rejectSteering() { let next = steering; steering = nil; next?.resume(throwing: AISteeringError.unavailable) }
    func sendPrompt(_ prompt: String, cliType: AICLIType, workingDirectory: URL?, sessionId: String?,
                    allowsWorkspaceEdits: Bool, options: AIRequestOptions,
                    streamHandler: @escaping @MainActor @Sendable (String) -> Void) async throws -> CLIPromptResult {
        precondition(pending == nil, "queue must never overlap requests")
        prompts.append(prompt); self.options.append(options)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ text: String = "done") { let next = pending; pending = nil; next?.resume(returning: .init(response: text, sessionId: "fixture")) }
    func fail() { let next = pending; pending = nil; next?.resume(throwing: AISteeringError.unavailable) }
    func cancel() { let next = pending; pending = nil; next?.resume(throwing: CancellationError()) }
}

@MainActor func checkQueue(in folder: URL) async throws {
    // Cancellation and a retry may use the same message identity. Only the
    // current operation token may consume it or unblock automatic dispatch.
    let queue = AIChatSubmissionQueue()
    let identity = UUID()
    let message = AIQueuedMessage(id: identity, text: "pending", conversationID: identity,
        project: folder, provider: .claude, mode: .plan, options: .init(), taggedIDs: [],
        document: nil, context: .init(entries: [], text: ""))
    queue.enqueue(message)
    precondition(queue.next(project: folder, provider: .claude, isBusy: false)?.id == identity)
    precondition(queue.next(project: folder, provider: .chatgpt, isBusy: false) == nil)
    let oldAttempt = queue.beginSteering(identity)!
    precondition(queue.next(project: folder, provider: .claude, isBusy: false) == nil)
    queue.remove(identity)
    precondition(queue.messages.count == 1 && queue.recoverableMessage(identity) == nil)
    queue.cancel(); queue.resume()
    let retry = queue.beginSteering(identity)!
    precondition(!queue.finishSteering(oldAttempt, accepted: true))
    precondition(queue.messages.count == 1 && queue.steeringMessageID == identity)
    queue.finishSteering(retry, accepted: false)
    precondition(queue.messages.count == 1 && queue.steeringMessageID == nil)
    let accepted = queue.beginSteering(identity)!
    queue.finishSteering(accepted, accepted: true)
    precondition(queue.messages.isEmpty)

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("queue fixture timed out")
    }
    let project = folder.appendingPathComponent("Queue.weaveproj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let suite = "queue-regression-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let executor = QueueExecutor()
    let vm = AIAssistantViewModel(modelDefaults: defaults, executor: executor)
    vm.completeConnection(.claude); vm.setProject(project)
    vm.chatMode = .plan; vm.inputText = "first"; vm.sendMessage()
    try await wait { executor.pending != nil }
    for text in ["second", "third", "fourth"] {
        vm.chatMode = .plan; vm.inputText = text; vm.sendMessage()
    }
    precondition(executor.prompts.count == 1 && vm.queuedMessages.map(\.text) == ["second", "third", "fourth"])
    let second = vm.queuedMessages[0].id, third = vm.queuedMessages[1].id, fourth = vm.queuedMessages[2].id
    vm.moveQueuedMessage(fourth, to: second)
    precondition(vm.queuedMessages.map(\.text) == ["fourth", "second", "third"])
    vm.moveQueuedMessage(fourth, to: third)
    precondition(vm.queuedMessages.map(\.text) == ["second", "third", "fourth"])
    // Same drag: row 1 -> row 2 -> row 3 -> back to row 2.
    vm.moveQueuedMessage(second, to: third)
    precondition(vm.queuedMessages.map(\.text) == ["third", "second", "fourth"])
    vm.moveQueuedMessage(second, to: fourth)
    precondition(vm.queuedMessages.map(\.text) == ["third", "fourth", "second"])
    vm.moveQueuedMessage(second, to: fourth)
    precondition(vm.queuedMessages.map(\.text) == ["third", "second", "fourth"])
    vm.moveQueuedMessage(second, to: third)
    vm.chatMode = .plan; vm.inputText = "draft being edited"
    vm.recoverQueuedMessage(third)
    precondition(vm.inputText == "third" && vm.queuedMessages.map(\.text) == ["second", "draft being edited", "fourth"])
    vm.inputText = "third revised"; vm.sendMessage()
    precondition(vm.queuedMessages.last?.text == "third revised" && vm.inputText.isEmpty)
    vm.removeQueuedMessage(fourth)
    vm.inputText = "keep this draft"
    vm.sendImmediateMessage()
    precondition(vm.inputText == "keep this draft" && vm.isProcessing && executor.prompts.count == 1)
    executor.finish()
    try await wait { executor.prompts.count == 2 && executor.pending != nil }
    precondition(executor.prompts[1].contains("second") && vm.inputText == "keep this draft")
    executor.finish()
    try await wait { executor.prompts.count == 3 && executor.pending != nil }
    precondition(executor.prompts[2].contains("draft being edited"))
    executor.fail()
    try await wait { !vm.isProcessing }
    precondition(vm.queuedMessages.count == 1 && vm.inputText == "keep this draft")
    vm.resumeQueue()
    try await wait { executor.prompts.count == 4 && executor.pending != nil }
    precondition(executor.prompts[3].contains("third revised"))
    vm.chatMode = .plan; vm.inputText = "after stop"; vm.sendMessage()
    vm.cancelSend()
    try await Task.sleep(for: .milliseconds(30))
    precondition(vm.queuedMessages.count == 1 && executor.prompts.count == 4)
    vm.resumeQueue()
    try await wait { executor.prompts.count == 5 && executor.pending != nil }
    let other = folder.appendingPathComponent("OtherQueue.weaveproj")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    vm.setProject(other)
    try await Task.sleep(for: .milliseconds(30))
    precondition(vm.messages.isEmpty && vm.queuedMessages.isEmpty && !vm.isProcessing)
    print("PASS queue FIFO, reorder both directions, recover/swap, delete, draft preservation, failure pause, resume, cancellation and project ownership")
}

@MainActor func checkActiveTurn(in folder: URL) async throws {
    let fixture = folder.appendingPathComponent("app-server-fixture.py")
    let script = #"""
#!/usr/bin/env python3
import sys,json

def emit(obj):
    print(json.dumps(obj),flush=True)
for line in sys.stdin:
    m=json.loads(line); method=m['method']; p=m.get('params',{})
    if method=='initialize': emit({'id':m['id'],'result':{}})
    elif method=='initialized': pass
    elif method in ('thread/start','thread/resume'):
        assert p['approvalPolicy']=='never' and p['sandbox']=='read-only'
        emit({'id':m['id'],'result':{'thread':{'id':'thread-test'}}})
    elif method=='turn/start':
        emit({'id':m['id'],'result':{'turn':{'id':'turn-test'}}})
        emit({'method':'turn/started','params':{'threadId':'thread-test','turn':{'id':'turn-test'}}})
        emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'turn-test','delta':'working'}})
    elif method=='turn/steer':
        assert p['threadId']=='thread-test' and p['expectedTurnId']=='turn-test'
        text=p['input'][0]['text']
        if text=='reject':
            emit({'id':m['id'],'error':{'code':-32600,'message':'rejected'}})
            continue
        emit({'method':'item/completed','params':{'threadId':'thread-test','turnId':'turn-test','item':{'type':'agentMessage','phase':'final_answer','text':text}}})
        # Deliberately complete before acknowledging steering: transport must stay open.
        emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed'}}})
        emit({'id':m['id'],'result':{'turnId':'turn-test'}})
    else: raise AssertionError(method)
"""#
    try script.write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let turn = CodexActiveTurn()
    var streamed = ""
    let task = Task { try await turn.run(path: fixture.path, prompt: "first", directory: folder,
        sessionID: nil, options: .init(), allowsWorkspaceEdits: false, compactLimit: nil) { streamed += $0 } }
    for _ in 0..<400 { if !streamed.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
    precondition(streamed == "working")
    do { try await turn.steer("reject"); preconditionFailure("rejected steering accepted") } catch {}
    try await turn.steer("추가 지시")
    let result = try await task.value
    precondition(result.response == "추가 지시" && result.sessionId == "thread-test")
    do { try await turn.steer("too late"); preconditionFailure("steered completed turn") } catch {}
    print("PASS app-server same-turn steering, rejection without interruption, completion-before-ack race and late-steer rejection")
}


@MainActor func checkSteeringViewModel(in folder: URL) async throws {
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("steering fixture timed out")
    }
    let fixture = folder.appendingPathComponent("codex")
    try """
    #!/usr/bin/env python3
    import sys,json
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' in m:
            result={'account':{'type':'chatgpt','email':'fixture','planType':'fixture'}} if m['method']=='account/read' else {}
            print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """.write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let oldPath = UserSettings.shared.path
    UserSettings.shared.path = fixture
    UserSettings.shared.aiAssistantEnabled = false
    defer { UserSettings.shared.path = oldPath; UserSettings.shared.aiAssistantEnabled = false }
    let project = folder.appendingPathComponent("Steering.weaveproj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let executor = QueueExecutor()
    let vm = AIAssistantViewModel(executor: executor)
    vm.completeConnection(.chatgpt); vm.setProject(project)
    await vm.chatGPTAccount.refresh()
    precondition(vm.chatGPTAccount.account != nil)
    vm.chatMode = .plan; vm.inputText = "original instruction"; vm.sendMessage()
    try await wait { executor.pending != nil }
    vm.chatMode = .plan; vm.inputText = "queued steering"; vm.sendMessage()
    let queuedID = vm.queuedMessages[0].id
    vm.steerQueuedMessage(queuedID); vm.steerQueuedMessage(queuedID)
    try await wait { executor.steering != nil }
    precondition(executor.instructions.count == 1 && vm.queuedMessages.count == 1)
    vm.inputText = "new draft stays"
    executor.finish()
    try await wait { !vm.isProcessing }
    precondition(executor.prompts.count == 1, "queue cannot drain while acknowledgement is pending")
    executor.acceptSteering()
    try await wait { vm.steeringMessageID == nil }
    precondition(vm.queuedMessages.isEmpty && vm.inputText == "new draft stays")
    let persisted = try JSONAIHistoryRepository().load(from: project)!
    precondition(persisted.session.messages.filter { $0.role == .user }.map(\.content) == ["original instruction", "queued steering"])
    vm.chatMode = .plan; vm.inputText = "followup"; vm.sendMessage()
    try await wait { executor.pending != nil }
    precondition(executor.prompts.last!.contains("original instruction") && executor.prompts.last!.contains("queued steering"))
    vm.inputText = "rejected extra"; vm.sendImmediateMessage()
    try await wait { executor.steering != nil }
    executor.rejectSteering()
    try await wait { vm.steeringMessageID == nil }
    precondition(vm.inputText == "rejected extra" && vm.isProcessing)
    vm.sendImmediateMessage()
    try await wait { executor.steering != nil }
    vm.inputText = "typed during acknowledgement"
    executor.acceptSteering()
    try await wait { vm.steeringMessageID == nil }
    precondition(vm.inputText == "typed during acknowledgement" && vm.isProcessing)
    vm.cancelSend(); vm.chatGPTAccount.cancelLogin()
    print("PASS steering acknowledgement boundary, duplicate suppression, persisted history, original context retention, rejection and concurrent draft preservation")
}


@MainActor func checkChatDrafts(in folder: URL) async throws {
    let wasEnabled = UserSettings.shared.aiAssistantEnabled
    let oldProvider = UserSettings.shared.aiAssistantCLIType
    UserSettings.shared.aiAssistantEnabled = false
    defer { UserSettings.shared.aiAssistantEnabled = wasEnabled; UserSettings.shared.aiAssistantCLIType = oldProvider }
    let suite = "draft-regression-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let project = folder.appendingPathComponent("Drafts.weaveproj")
    let other = folder.appendingPathComponent("OtherDrafts.weaveproj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let executor = QueueExecutor()
    let vm = AIAssistantViewModel(modelDefaults: defaults, executor: executor)
    vm.completeConnection(.claude); vm.setProject(project)
    let a = UUID(), b = UUID()
    vm.inputText = "새 채팅 초안\n😀 "
    vm.selectedCardId = a
    precondition(vm.inputText.isEmpty)
    vm.inputText = "A 미완성  "
    let oldBinding = vm.chatInputBinding
    vm.selectedCardId = b
    precondition(vm.inputText.isEmpty)
    vm.inputText = "B 초안"
    oldBinding.wrappedValue = "late composition callback"
    precondition(vm.inputText == "B 초안")
    vm.selectedCardId = a
    precondition(vm.inputText == "A 미완성  ")
    vm.selectedCardId = nil
    precondition(vm.inputText == "새 채팅 초안\n😀 ")
    vm.setProject(other); vm.selectedCardId = a
    precondition(vm.inputText.isEmpty)
    vm.inputText = "다른 프로젝트"
    vm.setProject(project); vm.selectedCardId = a
    precondition(vm.inputText == "A 미완성  ")
    UserSettings.shared.aiAssistantEnabled = false
    let reopened = AIAssistantViewModel(modelDefaults: UserDefaults(suiteName: suite)!, executor: QueueExecutor())
    reopened.completeConnection(.claude); reopened.setProject(project); reopened.selectedCardId = b
    precondition(reopened.inputText == "B 초안", "draft persists across view model reconstruction")
    reopened.inputText = ""
    reopened.selectedCardId = a; reopened.selectedCardId = b
    precondition(reopened.inputText.isEmpty, "explicitly cleared draft must not return")
    // Send clears only its owning draft; switching during a failure cannot fill another input.
    vm.selectedCardId = nil; vm.chatMode = .plan; vm.inputText = "send me"
    precondition(vm.sendMessage())
    let sent = vm.selectedCardId!
    precondition(vm.inputText.isEmpty)
    vm.selectedCardId = nil
    precondition(vm.inputText.isEmpty, "new-chat draft consumed on send")
    vm.selectedCardId = a
    for _ in 0..<400 { if executor.pending != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    precondition(executor.pending != nil)
    executor.fail()
    for _ in 0..<400 { if !vm.isProcessing { break }; try await Task.sleep(for: .milliseconds(5)) }
    precondition(vm.inputText == "A 미완성  ", "failure must not overwrite another conversation")
    vm.selectedCardId = sent; vm.inputText = "to delete"
    vm.deleteCard(id: sent)
    vm.selectedCardId = sent
    precondition(vm.inputText.isEmpty, "deleting conversation clears its cached draft")
    vm.selectedCardId = a; vm.inputText = "clear history"
    vm.clearHistory(); vm.selectedCardId = a
    precondition(vm.inputText.isEmpty, "history clear removes project drafts")
    vm.setProject(other); vm.selectedCardId = a
    precondition(vm.inputText == "다른 프로젝트", "history clear is project scoped")
    print("PASS chat draft ID isolation, new-chat draft, Unicode/whitespace, late binding, project isolation, persistence, send, failure, deletion and clear")
}
