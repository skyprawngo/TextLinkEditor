//
//  AIAssistantContainerView.swift
//  TextlinkEditor
//
//  AI 어시스턴트 메인 컨테이너 - 상태별 뷰 분기
//

import SwiftUI

struct AIAssistantContainerView: View {
    @State private var viewModel = AIAssistantViewModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var aiAssistantEnabled = UserSettings.shared.aiAssistantEnabled

    /// 상세 뷰 모드 여부 바인딩 (외부에서 관찰 및 수정 가능)
    @Binding var isInDetailView: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.collaboration.showingPanel, let notice = viewModel.collaboration.notification {
                Button { viewModel.collaboration.showingPanel = true } label: {
                    Label(notice, systemImage: "person.2.wave.2").font(.caption)
                }.buttonStyle(.borderless).padding(.horizontal, 10)
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(12)
            }
            if aiAssistantEnabled, case .connected(let type) = viewModel.connectionState {
                chatView(for: type)
            } else {
                ContentUnavailableView {
                    Label(L10n.get("ai.workspace.title"), systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(L10n.get("ai.workspace.connectionHint"))
                } actions: {
                    Button(L10n.get("ai.workspace.settings")) { openSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.chatGPTAccount.account) { _, account in
            guard viewModel.selectedCLIType == .chatgpt else { return }
            if account != nil {
                if case .connected(.chatgpt) = viewModel.connectionState {}
                else { viewModel.completeConnection(.chatgpt) }
            }
            else { viewModel.cancelSend(); viewModel.connectionState = .ready(.chatgpt) }
        }
        .onChange(of: viewModel.selectedCardId) { _, newValue in
            // 내부 상태 변경 → 외부로 전파
            let newIsInDetailView = newValue != nil
            if isInDetailView != newIsInDetailView {
                isInDetailView = newIsInDetailView
            }
        }
        .onChange(of: isInDetailView) { _, newValue in
            // 외부에서 false로 변경 시 → 내부 상태도 초기화 (뒤로가기 동작)
            if !newValue && viewModel.selectedCardId != nil {
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.selectedCardId = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            syncWithUserSettings()
        }
    }

    private func openSettings() {
        UserDefaults.standard.set(SettingsTab.ai.rawValue, forKey: "settings.selectedTab")
        openWindow(id: "settings")
    }

    private func chatView(for cliType: AICLIType) -> some View {
        AIChatView(
            cliType: cliType,
            messages: $viewModel.messages,
            inputText: viewModel.chatInputBinding,
            includeCurrentDocument: $viewModel.includeCurrentDocument,
            taggedCardIds: $viewModel.taggedCardIds,
            selectionState: $viewModel.selectionState,
            selectedCardId: $viewModel.selectedCardId,
            isProcessing: viewModel.isProcessing,
            onSend: { cardId in viewModel.sendMessage(continueFromCardId: cardId) },
            onImmediateSend: viewModel.sendImmediateMessage,
            queuedMessages: viewModel.queuedMessages,
            steeringMessageID: viewModel.steeringMessageID,
            onQueueRemove: viewModel.removeQueuedMessage,
            onQueueRecover: viewModel.recoverQueuedMessage,
            onQueueSteer: viewModel.steerQueuedMessage,
            onQueueMove: viewModel.moveQueuedMessage,
            onQueueResume: viewModel.resumeQueue,
            onCancel: viewModel.cancelSend,
            onClearHistory: viewModel.clearHistory,
            onDeleteCard: viewModel.deleteCard,
            onTagChanged: viewModel.saveTaggedCards,
            onSelectionResponse: viewModel.sendSelectionResponse,
            onPreviewDocument: viewModel.currentDocumentSnapshot,
            showingHistory: $viewModel.showingHistory
        )
    }

    // MARK: - Sync

    private func syncWithUserSettings() {
        let newEnabled = UserSettings.shared.aiAssistantEnabled
        if aiAssistantEnabled != newEnabled || viewModel.selectedCLIType?.rawValue != UserSettings.shared.aiAssistantCLIType {
            aiAssistantEnabled = newEnabled
            viewModel.loadSavedState()
        }
    }
}

#Preview {
    AIAssistantContainerView(isInDetailView: .constant(false))
        .frame(width: 350, height: 600)
}

/// App settings and the editor share one account and request owner.
struct AIConnectionSettingsContent: View {
    @Bindable var viewModel: AIAssistantViewModel
    var body: some View { connectionStateView }
    // MARK: - Connection State View

    @ViewBuilder
    private var connectionStateView: some View {
        switch viewModel.connectionState {
        case .inactive:
            AIInactiveView(onConnectTapped: viewModel.startConnection)

        case .selectingAI:
            AISetupView(
                selectedCLIType: $viewModel.selectedCLIType,
                onConfirm: viewModel.confirmAISelection,
                onCancel: viewModel.cancelSetup
            )

        case .checkingCLI(let cliType):
            cliInstallGuide(for: cliType, status: .checking)

        case .cliNotInstalled(let cliType), .installingCLI(let cliType):
            cliInstallGuide(for: cliType, status: viewModel.installStatus)

        case .ready(let cliType):
            if cliType == .chatgpt {
                VStack {
                    ChatGPTAccountView(service: viewModel.chatGPTAccount, compact: false)
                    Button(L10n.get("ai.chat.changeAI")) { viewModel.changeAI() }
                }
            }
            else { Button(L10n.get("common.retry")) { viewModel.checkCLIInstallation(cliType) } }
        case .connected(let cliType):
            Form {
                Section(L10n.get("settings.aiProvider")) {
                    LabeledContent(L10n.get("settings.aiProvider"), value: cliType.displayName)
                    Button(L10n.get("ai.chat.changeAI")) { viewModel.changeAI() }
                        .disabled(viewModel.isProcessing)
                }
                if cliType == .chatgpt {
                    Section(L10n.get("ai.oauth.manage")) {
                        ChatGPTAccountView(service: viewModel.chatGPTAccount, compact: false)
                    }
                }
                ForEach(AIConversationCategory.allCases, id: \.self) { category in
                    Section(L10n.get(category == .chat ? "ai.settings.sidebar" : category == .inlineEdit ? "ai.settings.inline" : "git.aiModel")) {
                        Picker(L10n.get("ai.model.title"), selection: Binding(
                            get: { viewModel.selectedModel(for: cliType, category: category)?.id ?? "" },
                            set: { viewModel.selectModel($0, for: cliType, category: category) })) {
                            if viewModel.selectedModel(for: cliType, category: category) == nil {
                                Text(L10n.get("ai.model.choose")).tag("")
                            }
                            ForEach(viewModel.models(for: cliType)) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        Picker(L10n.get("ai.effort.title"), selection: Binding(
                            get: { viewModel.requestOptions(for: cliType, category: category).effort ?? "" },
                            set: { viewModel.selectEffort($0, for: cliType, category: category) })) {
                            if viewModel.requestOptions(for: cliType, category: category).effort == nil {
                                Text(L10n.get("ai.effort.unavailable")).tag("")
                            }
                            ForEach(viewModel.selectedModel(for: cliType, category: category)?.efforts ?? [], id: \.self) { effort in
                                Text(L10n.get("ai.effort." + effort)).tag(effort)
                            }
                        }
                        .disabled(viewModel.selectedModel(for: cliType, category: category)?.efforts.isEmpty ?? true)
                        Text(L10n.get(category == .commitMessage ? "git.autoCommitHint" : "ai.settings.separateDefaults")).font(.caption).foregroundStyle(.secondary)
                        if cliType == .chatgpt {
                            Button(L10n.get("ai.model.refresh")) { Task { await viewModel.refreshModels() } }
                        }
                    }
                }
                .disabled(viewModel.isProcessing || viewModel.modelsLoading)
                .task(id: cliType) {
                    if cliType == .chatgpt { await viewModel.refreshModels() }
                }
                Section {
                    Button(L10n.get("ai.chat.disconnect")) { viewModel.disconnect() }
                        .disabled(viewModel.isProcessing)
                } footer: {
                    Text(L10n.get("ai.workspace.disconnectHint"))
                }
            }.formStyle(.grouped)

        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Subviews

    private func cliInstallGuide(for cliType: AICLIType, status: CLIInstallationStatus) -> some View {
        CLIInstallGuideView(
            cliType: cliType,
            installStatus: status,
            onOpenInstallPage: viewModel.openInstallPage,
            onRetryCheck: { viewModel.checkCLIInstallation(cliType) },
            onSelectCLIPath: viewModel.selectCLIPath,
            onCancel: viewModel.cancelSetup
        )
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text(L10n.get("ai.error.title"))
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button(L10n.get("common.retry"), action: viewModel.cancelSetup)
                .buttonStyle(.borderedProminent)
        }
    }

}
