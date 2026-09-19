import SwiftUI

struct AIDocumentSnapshot {
    let name: String
    let content: String
}

@MainActor @Observable
final class AIAssistantViewModel {
    static let shared = AIAssistantViewModel()
    let chatGPTAccount = ChatGPTAccountService()
    let collaboration = CollaborationCoordinator()
    var connectionState: AIConnectionState = .inactive
    var selectedCLIType: AICLIType?
    var installStatus: CLIInstallationStatus = .unknown
    var messages: [AIMessage] = []
    var inputText = "" {
        didSet {
            guard inputText != oldValue else { return }
            draftRevision &+= 1
            drafts.save(inputText, project: projectFolderURL, conversation: selectedCardId)
        }
    }
    private var draftRevision = 0
    private var modeOverrides: [UUID: AIChatMode] = [:]
    private var newChatMode: AIChatMode?
    var chatMode: AIChatMode {
        get {
            guard let selectedCardId else { return newChatMode ?? .conversation }
            return modeOverrides[selectedCardId] ?? .conversation
        }
        set {
            if let selectedCardId { modeOverrides[selectedCardId] = newValue }
            else { newChatMode = newValue }
        }
    }
    var hasChatModeTag: Bool {
        if let selectedCardId { return modeOverrides[selectedCardId] != nil }
        return newChatMode != nil
    }
    func clearChatModeTag() {
        if let selectedCardId { modeOverrides.removeValue(forKey: selectedCardId) }
        else { newChatMode = nil }
    }
    var isProcessing = false
    private let submissions = AIChatSubmissionQueue()
    var queuedMessages: [AIQueuedMessage] { submissions.messages }
    var steeringMessageID: UUID? { submissions.steeringMessageID }
    private var activeChat: AIActiveChatRequest?
    private var recoveredDraft: AIQueuedMessage?

    var taggedCardIds: Set<UUID> = []
    var selectionState: CLISelectionState = .empty
    var showingHistory = false
    var selectedCardId: UUID? {
        didSet {
            guard selectedCardId != oldValue else { return }
            draftRevision &+= 1 // A late response must not consume another chat's draft.
            recoveredDraft = nil
            inputText = drafts.text(project: projectFolderURL, conversation: selectedCardId)
        }
    }
    var composerID: String { (projectFolderURL?.absoluteString ?? "") + "/" + (selectedCardId?.uuidString ?? "new") }
    var chatInputBinding: Binding<String> {
        let project = projectFolderURL, conversation = selectedCardId
        return Binding(get: {
            self.projectFolderURL == project && self.selectedCardId == conversation
                ? self.inputText : self.drafts.text(project: project, conversation: conversation)
        }, set: { value in
            guard self.projectFolderURL == project, self.selectedCardId == conversation else { return }
            self.inputText = value
        })
    }
    var includeCurrentDocument = false
    var errorMessage: String?
    var inlineErrorMessage: String?
    private var historyLoadFailed = false
    private var projectFolderURL: URL?
    private var cardSessionIds: [UUID: String] = [:]
    private let processManager: any AIRequestExecuting
    private let history: any AIHistoryRepository
    private let drafts: AIChatDraftStore
    private var requestTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var requestId: UUID?

    var availableModels: [AIModelOption] {
        get { modelPreferences.availableModels }
        set { modelPreferences.availableModels = newValue }
    }
    var modelsLoading = false
    var modelsError = false
    private var modelCatalogOwner = UUID()
    let modelPreferences: AIModelPreferences
    var modelSelections: [String: String] {
        get { modelPreferences.modelSelections }
        set { modelPreferences.modelSelections = newValue }
    }
    func models(for type: AICLIType) -> [AIModelOption] { modelPreferences.models(for: type) }
    func selectedModel(for type: AICLIType, category: AIConversationCategory = .chat) -> AIModelOption? {
        modelPreferences.selectedModel(for: type, category: category)
    }
    func selectModel(_ id: String, for type: AICLIType, category: AIConversationCategory = .chat) {
        modelPreferences.selectModel(id, for: type, category: category)
    }
    func selectEffort(_ effort: String, for type: AICLIType, category: AIConversationCategory = .chat) {
        modelPreferences.selectEffort(effort, for: type, category: category)
    }
    func requestOptions(for type: AICLIType, category: AIConversationCategory = .chat) -> AIRequestOptions {
        modelPreferences.requestOptions(for: type, category: category)
    }
    func refreshModels() async {
        let owner = UUID()
        modelCatalogOwner = owner
        modelsLoading = true
        modelsError = false
        defer { if modelCatalogOwner == owner { modelsLoading = false } }
        do {
            let models = try await chatGPTAccount.availableModels()
            guard modelCatalogOwner == owner else { return }
            availableModels = models
            for category in AIConversationCategory.allCases {
                if let model = selectedModel(for: .chatgpt, category: category) {
                    selectModel(model.id, for: .chatgpt, category: category)
                }
            }
            modelsError = models.isEmpty
        } catch {
            guard modelCatalogOwner == owner else { return }
            modelsError = true
        }
    }

    init(modelDefaults: UserDefaults = .standard, history: any AIHistoryRepository = JSONAIHistoryRepository(),
         executor: (any AIRequestExecuting)? = nil) {
        modelPreferences = AIModelPreferences(modelDefaults: modelDefaults)
        self.history = history
        self.drafts = AIChatDraftStore(defaults: modelDefaults)
        self.processManager = executor ?? CLIProcessManager()
        loadSavedState()
        collaboration.runtime = { [weak self] in
            guard let self, !self.isProcessing, case .connected(let provider) = self.connectionState,
                  provider != .chatgpt || self.chatGPTAccount.account != nil else { return nil }
            return (provider, self.requestOptions(for: provider), self.processManager)
        }
    }

    func loadSavedState() {
        guard UserSettings.shared.aiAssistantEnabled else {
            cancelSend()
            connectionState = .inactive
            return
        }
        guard let type = AICLIType(rawValue: UserSettings.shared.aiAssistantCLIType) else {
            connectionState = .selectingAI
            return
        }
        selectedCLIType = type
        checkCLIInstallation(type)
    }

    func setProject(_ url: URL?) {
        guard url != projectFolderURL else { return }
        cancelSend()
        submissions.clear()
        recoveredDraft = nil
        projectFolderURL = url
        messages = []
        taggedCardIds = []
        cardSessionIds = [:]
        selectedCardId = nil
        inputText = drafts.text(project: url, conversation: nil)
        modeOverrides = [:]
        newChatMode = nil
        includeCurrentDocument = false
        errorMessage = nil
        inlineErrorMessage = nil
        if let url, case .connected(let type) = connectionState { loadHistory(type, url: url) }
        collaboration.setProject(url)
    }

    private func loadHistory(_ type: AICLIType, url: URL) {
        do {
            let snapshot = try history.load(from: url)
            historyLoadFailed = false
            messages = snapshot?.session.messages ?? []
            taggedCardIds = snapshot?.metadata.taggedCardIds ?? []
            // A session belongs to the provider of its last response, not the last
            // provider selected for the project as a whole.
            cardSessionIds = snapshot?.sessionIds ?? [:]
            selectedCardId = messages.last(where: {
                $0.role == .user && $0.category == .chat && ($0.provider ?? snapshot?.metadata.cliType) == type.rawValue
            }).map { $0.conversationId ?? $0.id }
        } catch {
            historyLoadFailed = true
            errorMessage = L10n.get("ai.error.historyLoadFailed")
        }
    }

    func resumableSession(for conversationId: UUID, provider: AICLIType) -> String? {
        guard let last = messages.last(where: {
            ($0.conversationId ?? $0.id) == conversationId && $0.role == .assistant
        }), last.category == .chat, last.outcome == nil || last.outcome == "completed",
           last.provider == provider.rawValue else { return nil }
        return cardSessionIds[conversationId]
    }

    func prepareDraftAction(_ instruction: String) {
        selectedCardId = nil
        inputText = "/작성 " + instruction
        includeCurrentDocument = true
    }

    func generateCommitMessage(patch: String) async throws -> String {
        guard !isProcessing, !collaboration.isWorking, case .connected(let provider) = connectionState,
              provider != .chatgpt || chatGPTAccount.account != nil else {
            throw AIRequestPreparationError.message(L10n.get("git.autoCommitUnavailable"))
        }
        guard selectedModel(for: provider, category: .commitMessage) != nil else {
            throw AIRequestPreparationError.message(L10n.get("ai.model.retry"))
        }
        let owner = UUID()
        requestId = owner
        isProcessing = true
        defer {
            if requestId == owner { requestId = nil; isProcessing = false; drainQueue() }
        }
        var options = requestOptions(for: provider, category: .commitMessage)
        options.readsProjectFiles = false
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TextlinkCommit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try await processManager.sendPrompt(AICommitMessage.prompt(patch: patch), cliType: provider,
            workingDirectory: temporary, sessionId: nil, allowsWorkspaceEdits: false, options: options, streamHandler: { _ in })
        try Task.checkCancellation()
        guard requestId == owner else { throw CancellationError() }
        return try AICommitMessage.decode(result.response)
    }

    func startConnection() {
        UserSettings.shared.aiAssistantEnabled = true
        loadSavedState()
    }

    func confirmAISelection(_ type: AICLIType) {
        UserSettings.shared.aiAssistantCLIType = type.rawValue
        selectedCLIType = type
        checkCLIInstallation(type)
    }

    func checkCLIInstallation(_ type: AICLIType, skipAutoDetect: Bool = false) {
        setupTask?.cancel()
        connectionState = .checkingCLI(type)
        installStatus = .checking
        setupTask = Task { [weak self] in
            let status = await CLIDetector.shared.checkInstallation(for: type)
            guard !Task.isCancelled, let self else { return }
            installStatus = status
            if case .installed = status {
                if type == .chatgpt {
                    await chatGPTAccount.refresh()
                    guard !Task.isCancelled else { return }
                    if chatGPTAccount.account != nil { completeConnection(type) }
                    else { connectionState = .ready(type) }
                } else { completeConnection(type) }
            }
            else { connectionState = .cliNotInstalled(type) }
        }
    }

    func completeConnection(_ type: AICLIType) {
        cancelSend()
        submissions.clear()
        UserSettings.shared.aiAssistantEnabled = true
        UserSettings.shared.aiAssistantCLIType = type.rawValue
        selectedCLIType = type
        connectionState = .connected(type)
        selectedCardId = nil
        if let url = projectFolderURL { loadHistory(type, url: url) }
    }

    func changeAI() { cancelSend(); chatGPTAccount.cancelLogin(); connectionState = .selectingAI }
    func disconnect() {
        cancelSend()
        setupTask?.cancel()
        chatGPTAccount.cancelLogin()
        UserSettings.shared.aiAssistantEnabled = false
        UserSettings.shared.aiAssistantCLIType = ""
        connectionState = .inactive
        selectedCLIType = nil
    }
    func cancelSetup() { disconnect(); installStatus = .unknown }
    func openInstallPage() {
        if let selectedCLIType { CLIInstaller.shared.openInstallPage(for: selectedCLIType) }
    }
    func selectCLIPath(_ url: URL) {
        guard let type = selectedCLIType else { return }
        guard CLIDetector.isValidExecutable(url, for: type) else {
            installStatus = .installationFailed(L10n.get("ai.error.invalidExecutable"))
            return
        }
        if UserSettings.shared.setAICLIPath(url) { checkCLIInstallation(type) }
    }

    /// Both preview and send use the flushed editor cache, including unsaved changes.
    func currentDocumentSnapshot() -> AIDocumentSnapshot? {
        EditorTabManager.shared.flushEditor()
        guard let tab = EditorTabManager.shared.selectedTab,
              let content = EditorTabManager.shared.getCachedContent(for: tab.url) else { return nil }
        return AIDocumentSnapshot(name: tab.title, content: content)
    }

    @discardableResult
    func sendMessage(continueFromCardId: UUID? = nil, inlineInput: String? = nil, inlineRevision: ManuscriptRevision? = nil,
                     queued: AIQueuedMessage? = nil) -> Bool {
        if queued == nil && inlineInput == nil && (isProcessing || !queuedMessages.isEmpty || recoveredDraft != nil) {
            enqueueMessage(conversationID: continueFromCardId)
            return false
        }
        func reportPreparationError(_ message: String) {
            if inlineRevision != nil { inlineErrorMessage = message }
            else { errorMessage = message }
        }
        var requestInput = queued?.text ?? inlineInput ?? inputText
        let originalInput = requestInput
        guard !isProcessing, !collaboration.isWorking else { return false }
        if queued == nil, inlineInput == nil, let command = AIChatMode.parse(requestInput) {
            chatMode = command.mode
            requestInput = command.body
            if requestInput.isEmpty { inputText = ""; return false }
        }
        let attachDocument = queued.map { $0.document != nil } ?? (inlineInput == nil && includeCurrentDocument)
        guard !isProcessing, !collaboration.isWorking, !requestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .connected(let type) = connectionState else { return false }
        if type == .chatgpt && chatGPTAccount.account == nil { connectionState = .ready(type); return false }
        guard let projectURL = projectFolderURL else { reportPreparationError(L10n.get("ai.error.noProject")); return false }
        guard !UserSettings.shared.aiTerminalMode else {
            reportPreparationError(CLIProcessManager.CLIError.terminalUnavailable.localizedDescription)
            return false
        }
        guard !historyLoadFailed else { reportPreparationError(L10n.get("ai.error.historyLoadFailed")); return false }
        if inlineRevision != nil { inlineErrorMessage = nil }
        else { errorMessage = nil }
        let id = UUID()
        let userId = queued?.id ?? UUID()
        let continuedConversation = queued?.conversationID ?? continueFromCardId ?? (inlineInput == nil ? selectedCardId : nil)
        let conversationId = inlineRevision == nil ? (continuedConversation ?? userId) : userId
        let assistantId = UUID()
        var requestPersisted = false
        defer { if !requestPersisted { removeRequestArtifacts(ids: [assistantId]) } }
        let category: AIConversationCategory = inlineRevision == nil ? .chat : .inlineEdit
        if let savedModel = queued?.options.model ?? modelSelections[modelPreferences.preferenceKey(type, category)], !savedModel.isEmpty,
           !models(for: type).contains(where: { $0.id == savedModel }) {
            reportPreparationError(L10n.get("ai.model.retry"))
            return false
        }
        var options = queued?.options ?? requestOptions(for: type, category: category)
        options.readsProjectFiles = inlineRevision == nil
        options.allowsSteering = inlineInput == nil && inlineRevision == nil
        let mode = queued?.mode ?? chatMode
        let existingSession = inlineRevision == nil ? resumableSession(for: conversationId, provider: type) : nil
        let prepared: PreparedAIRequest
        do {
            prepared = try AIRequestPreparer().prepare(requestInput: requestInput, type: type,
                projectURL: projectURL, assistantId: assistantId, inlineRevision: inlineRevision,
                attachDocument: attachDocument, messages: messages, taggedCardIds: queued?.taggedIDs ?? taggedCardIds,
                existingSession: existingSession, continueFromCardId: continuedConversation, chatMode: mode,
                capturedDocument: queued?.document, capturedContext: queued?.context)
        } catch { reportPreparationError(error.localizedDescription); return false }
        messages.append(AIMessage(id: userId, role: .user, content: requestInput, conversationId: conversationId, kind: category.rawValue, provider: type.rawValue, model: options.model, reasoningEffort: options.effort, chatMode: inlineRevision == nil ? mode.rawValue : nil))
        messages.append(AIMessage(id: assistantId, role: .assistant, content: "", isStreaming: true, conversationId: conversationId, kind: category.rawValue, provider: type.rawValue, model: options.model, reasoningEffort: options.effort))
        guard persist() else { messages.removeLast(2); return false }
        requestPersisted = true
        if inlineInput == nil && queued == nil {
            inputText = ""
            if let selectedCardId { modeOverrides.removeValue(forKey: selectedCardId) }
            selectedCardId = conversationId
            modeOverrides.removeValue(forKey: conversationId)
            newChatMode = nil
        }
        let submittedDraftRevision = draftRevision
        isProcessing = true
        requestId = id
        if inlineInput == nil { activeChat = AIActiveChatRequest(request: id, assistant: assistantId, conversation: conversationId, provider: type) }
        requestTask = Task { [weak self] in
            guard let self else { return }
            let executor = AIWorkspaceProposalExecutor(base: processManager, requestID: assistantId, project: projectURL)
            var receivedResponse: String?
            do {
                let result = try await executor.sendPrompt(prepared.prompt, cliType: type, workingDirectory: projectURL,
                                                                 sessionId: existingSession, allowsWorkspaceEdits: prepared.allowsWorkspaceEdits, options: options) { [weak self] chunk in
                    guard let self, requestId == id, projectFolderURL == projectURL,
                          let index = messages.firstIndex(where: { $0.id == assistantId }) else { return }
                    let old = messages[index]
                    messages[index] = AIMessage(id: old.id, role: .assistant, content: old.content + chunk,
                                               timestamp: old.timestamp, isStreaming: true, conversationId: conversationId, kind: old.kind, provider: old.provider, model: old.model, reasoningEffort: old.reasoningEffort)
                }
                guard requestId == id, projectFolderURL == projectURL, !Task.isCancelled else { return }
                if let session = result.sessionId ?? existingSession {
                    cardSessionIds[conversationId] = session
                } else {
                    cardSessionIds.removeValue(forKey: conversationId)
                }
                receivedResponse = result.response
                if let inlineRevision {
                    let replacement = try InlineEditRequest.replacement(from: result.response)
                    try ManuscriptRevisionBridge.apply(inlineRevision, proposal: replacement,
                        selected: Set(inlineRevision.changes(proposal: replacement).map(\.id)), project: projectURL)
                    finish(assistantId, content: L10n.get("ai.inline.applied") + "\n\n" + replacement, outcome: "completed", usage: result.usage)
                } else {
                    finish(assistantId, content: result.response, outcome: "completed", usage: result.usage)
                }
            } catch {
                guard requestId == id, projectFolderURL == projectURL else { return }
                // A failed session may be missing or contain an incomplete turn.
                // A user retry rebuilds context from saved completed messages.
                cardSessionIds.removeValue(forKey: conversationId)
                // Accepted inline requests report only in their own history entry.
                // Never replace the unrelated sidebar conversation's error or draft.
                if inlineRevision == nil { errorMessage = error.localizedDescription }
                // Keep the prompt available for editing/retry without dropping its persisted failed turn.
                if inlineInput == nil && queued == nil && selectedCardId == conversationId && inputText.isEmpty && draftRevision == submittedDraftRevision { inputText = originalInput }
                let response = receivedResponse ?? messages.first(where: { $0.id == assistantId })?.content ?? ""
                let failureRecord = inlineRevision != nil && !response.isEmpty
                    ? error.localizedDescription + "\n\n" + response : error.localizedDescription
                finish(assistantId, content: failureRecord, outcome: "failed")
            }
        }
        return true
    }

    private func finish(_ messageId: UUID, content: String, outcome: String, usage: AIContextUsage? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let old = messages[index]
        messages[index] = AIMessage(id: old.id, role: .assistant, content: content, timestamp: old.timestamp,
                                   conversationId: old.conversationId, outcome: outcome, kind: old.kind, usage: usage, provider: old.provider, model: old.model, reasoningEffort: old.reasoningEffort)
        requestId = nil
        requestTask = nil
        isProcessing = false
        activeChat = nil
        let saved = persist()
        submissions.didFinishResponse(successfully: outcome == "completed" && saved)
        drainQueue()
    }

    func cancelSend() {
        collaboration.cancel()
        submissions.cancel()
        activeChat = nil
        requestId = nil // invalidate callbacks before touching process/UI state
        requestTask?.cancel()
        processManager.cancel()
        requestTask = nil
        if let index = messages.lastIndex(where: \.isStreaming) {
            let old = messages[index]
            if let root = old.conversationId { cardSessionIds.removeValue(forKey: root) }
            let content = old.content.isEmpty ? L10n.get("ai.chat.cancelled") : old.content + "\n\n" + L10n.get("ai.chat.cancelled")
            messages[index] = AIMessage(id: old.id, role: .assistant, content: content,
                                       timestamp: old.timestamp, conversationId: old.conversationId, outcome: "cancelled", kind: old.kind, provider: old.provider, model: old.model, reasoningEffort: old.reasoningEffort)
            _ = persist()
        }
        isProcessing = false
    }

    private func persist() -> Bool {
        guard !historyLoadFailed, let url = projectFolderURL, case .connected(let type) = connectionState else { return false }
        do {
            try history.save(messages: messages, taggedIds: taggedCardIds,
                                                    sessionIds: cardSessionIds, cliType: type.rawValue, to: url)
            return true
        } catch { errorMessage = L10n.get("ai.error.historySaveFailed"); return false }
    }
    func clearHistory() {
        cancelSend()
        submissions.clear()
        let previous = messages
        let tags = taggedCardIds
        let sessions = cardSessionIds
        messages = []; taggedCardIds = []; cardSessionIds = [:]
        if !persist() { messages = previous; taggedCardIds = tags; cardSessionIds = sessions }
        else {
            drafts.clear(project: projectFolderURL)
            selectedCardId = nil
            inputText = ""
            do {
                let ids = try projectFolderURL.map { try AIContextSelection.shared.savedRequestIDs(projectURL: $0) } ?? []
                removeRequestArtifacts(ids: ids.union(previous.map(\.id)))
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func saveTaggedCards() { _ = persist() }
    func deleteCard(id: UUID) {
        cancelSend()
        submissions.removeConversation(id)
        let previous = messages
        let tags = taggedCardIds
        let sessions = cardSessionIds
        messages.removeAll { ($0.conversationId ?? $0.id) == id }
        // Legacy assistant messages have no conversation ID; remove by pairing too.
        if let userIndex = previous.firstIndex(where: { $0.id == id }), userIndex + 1 < previous.count,
           previous[userIndex + 1].role == .assistant {
            let assistantId = previous[userIndex + 1].id
            messages.removeAll { $0.id == assistantId }
        }
        taggedCardIds.remove(id); cardSessionIds.removeValue(forKey: id)
        if !persist() { messages = previous; taggedCardIds = tags; cardSessionIds = sessions }
        else {
            drafts.save("", project: projectFolderURL, conversation: id)
            if selectedCardId == id { selectedCardId = nil }
            let retained = Set(messages.map(\.id))
            removeRequestArtifacts(previous.filter { !retained.contains($0.id) })
        }
    }
    private func removeRequestArtifacts(_ removed: [AIMessage]) {
        removeRequestArtifacts(ids: Set(removed.filter { $0.role == .assistant }.map(\.id)))
    }
    private func removeRequestArtifacts(ids: Set<UUID>) {
        guard let project = projectFolderURL else { return }
        var failures: [String] = []
        for id in ids {
            do { try ManuscriptRevisionBridge.remove(id: id, project: project) }
            catch { failures.append(error.localizedDescription) }
            do { try AIContextSelection.shared.removeManifest(requestID: id, projectURL: project) }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
    func sendSelectionResponse(_ optionId: Int) { /* interactive mode is no longer supported */ }
}

// MARK: - Sidebar submissions
extension AIAssistantViewModel {
    private func captureDraft(conversationID: UUID? = nil) throws -> AIQueuedMessage? {
        guard let project = projectFolderURL, case .connected(let provider) = connectionState,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let command = AIChatMode.parse(inputText)
        let body = command?.body ?? inputText
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let command { chatMode = command.mode; inputText = "" }
            return nil
        }
        let recovered = recoveredDraft
        let id = UUID()
        let document = includeCurrentDocument ? (recovered?.document ?? ManuscriptRevisionBridge.capture(id: id, project: project)) : nil
        if includeCurrentDocument && document == nil { throw AIRequestPreparationError.message(L10n.get("ai.error.contextUnavailable")) }
        return AIQueuedMessage(id: id, text: body, conversationID: conversationID ?? selectedCardId ?? id,
            project: project, provider: provider, mode: command?.mode ?? chatMode,
            options: recovered?.options ?? requestOptions(for: provider), taggedIDs: recovered?.taggedIDs ?? taggedCardIds,
            document: document, context: try recovered?.context ?? AIContextSelection.shared.manifest(projectURL: project))
    }

    private func consumeDraft() {
        inputText = ""
        clearChatModeTag()
        newChatMode = nil
        recoveredDraft = nil
    }

    func enqueueMessage(conversationID: UUID? = nil) {
        do {
            guard let draft = try captureDraft(conversationID: conversationID) else { return }
            submissions.enqueue(draft)
            consumeDraft()
            selectedCardId = draft.conversationID
            drainQueue()
        } catch { errorMessage = error.localizedDescription }
    }

    func resumeQueue() { submissions.resume(); drainQueue() }

    private func drainQueue() {
        guard case .connected(let provider) = connectionState,
              let next = submissions.next(project: projectFolderURL, provider: provider,
                                          isBusy: isProcessing || collaboration.isWorking) else { return }
        if sendMessage(queued: next) { submissions.didDispatch(next.id) }
        else { submissions.pause() }
    }

    func removeQueuedMessage(_ id: UUID) { submissions.remove(id) }
    func moveQueuedMessage(_ id: UUID, to target: UUID) { submissions.move(id, to: target) }

    func recoverQueuedMessage(_ id: UUID) {
        guard let recovered = submissions.recoverableMessage(id) else { return }
        do {
            // The source chat remains cached. Swap the destination chat's draft
            // into the queue, so recovering across chats cannot erase either draft.
            selectedCardId = recovered.conversationID
            let displaced = try captureDraft()
            guard submissions.recover(id, replacingWith: displaced) != nil else { return }
            consumeDraft()
            inputText = recovered.text
            chatMode = recovered.mode
            includeCurrentDocument = recovered.document != nil
            recoveredDraft = recovered
        } catch { errorMessage = error.localizedDescription }
    }

    func sendImmediateMessage() {
        guard isProcessing else { sendMessage(); return }
        do {
            guard let draft = try captureDraft() else { return }
            steer(draft, fromQueue: false)
        } catch { errorMessage = error.localizedDescription }
    }

    func steerQueuedMessage(_ id: UUID) {
        guard let draft = submissions.message(id) else { return }
        steer(draft, fromQueue: true)
    }

    private func steer(_ draft: AIQueuedMessage, fromQueue: Bool) {
        guard steeringMessageID == nil else { return }
        guard let active = activeChat, active.request == requestId,
              active.conversation == draft.conversationID, draft.project == projectFolderURL else {
            errorMessage = AISteeringError.unavailable.localizedDescription; return
        }
        guard active.provider == .chatgpt else {
            errorMessage = AISteeringError.unsupported.localizedDescription; return
        }
        let instruction: String
        do { instruction = try draft.steeringInstruction() }
        catch { errorMessage = error.localizedDescription; return }
        let originalDraftRevision = draftRevision
        guard let steeringToken = submissions.beginSteering(draft.id) else { return }
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            var accepted = false
            defer {
                if submissions.finishSteering(steeringToken, accepted: accepted) { drainQueue() }
            }
            do {
                try await processManager.steer(instruction)
                guard projectFolderURL == draft.project, submissions.ownsSteering(steeringToken),
                      let index = messages.firstIndex(where: { $0.id == active.assistant }) else { return }
                let response = messages[index]
                // The acknowledgement is the acceptance boundary. No second assistant turn is created.
                messages.insert(AIMessage(id: draft.id, role: .user, content: draft.text,
                    conversationId: active.conversation, provider: active.provider.rawValue,
                    model: response.model, reasoningEffort: response.reasoningEffort), at: index)
                if !fromQueue && draftRevision == originalDraftRevision { consumeDraft() }
                accepted = true
                if !persist() { submissions.pause() }
            } catch {
                guard projectFolderURL == draft.project, submissions.ownsSteering(steeringToken) else { return }
                errorMessage = error.localizedDescription // leave the queue/draft intact; never retry implicitly
            }
        }
    }
}
