//
//  AIChatView.swift
//  TextlinkEditor
//
//  대화 작업 공간: 기록 탐색과 첨부 선택은 보조 화면, 입력은 단일 AppKit 뷰.
//

import SwiftUI
import AppKit

// MARK: - Conversation workspace

struct AIChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cliType: AICLIType
    @Binding var messages: [AIMessage]
    @Binding var inputText: String
    @Binding var includeCurrentDocument: Bool
    @Binding var taggedCardIds: Set<UUID>
    @Binding var selectionState: CLISelectionState
    @Binding var selectedCardId: UUID?
    let isProcessing: Bool
    let onSend: (UUID?) -> Void
    let onCancel: () -> Void
    let onClearHistory: () -> Void
    let onDeleteCard: ((UUID) -> Void)?
    let onTagChanged: (() -> Void)?
    let onSelectionResponse: ((Int) -> Void)?
    var onPreviewDocument: () -> AIDocumentSnapshot? = { nil }
    @State private var modelSettings = AIAssistantViewModel.shared
    @State private var showingUsage = false
    @State private var inputFocusRequest = 0
    @State private var dismissedCommandDraft: String?
    @State private var showingModelControls = false
    @State private var inputHeight: CGFloat = 48
    @Binding var showingHistory: Bool
    @State private var showingContext = false
    @State private var showingPreview = false
    @State private var showingReferences = false
    @State private var revisionPresentation: AIWorkspaceRevision?
    @State private var revisionError = false
    @State private var completedWorkspaceRequests = Set<UUID>()
    @State private var documentPreview: AIDocumentSnapshot?
    @State private var historyQuery = ""
    @State private var isHistorySearchExpanded = false
    @State private var historyKind = 0
    @State private var pendingDeletion: UUID?
    private var activeFile: EditorTab? { EditorTabManager.shared.selectedTab }
    /// 메시지를 대화 카드로 변환
    private var conversationCards: [ConversationCard] {
        var cards: [ConversationCard] = []
        var currentRoot: UUID?
        for message in messages {
            if message.role == .user {
                let root = message.conversationId ?? message.id
                currentRoot = root
                if !cards.contains(where: { $0.id == root }) {
                    var card = ConversationCard(userMessage: message)
                    card.isTaggedForContext = taggedCardIds.contains(root)
                    cards.append(card)
                }
            } else if message.role == .assistant, let root = message.conversationId ?? currentRoot,
                      let index = cards.firstIndex(where: { $0.id == root }) {
                cards[index].assistantMessage = message
            }
        }
        return cards
    }

    private var detailMessages: [AIMessage] {
        guard let selectedCardId else { return [] }
        var root: UUID?
        return messages.filter { message in
            if message.role == .user { root = message.conversationId ?? message.id }
            return (message.conversationId ?? root) == selectedCardId
        }
    }


    private var isInlineRecord: Bool { detailMessages.first?.category == .inlineEdit }

    private var contextCount: Int { (includeCurrentDocument && activeFile != nil ? 1 : 0) + taggedCardIds.count }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Cross the composer's 12pt top inset and tuck another 12pt of
                // transcript behind its surface, without reaching its footer.
                VStack(spacing: isInlineRecord ? 0 : -24) {
                    AIChatTranscript(messages: detailMessages, conversationID: selectedCardId,
                        processing: isProcessing,
                        completedRequests: completedWorkspaceRequests,
                        project: ProjectManager.shared.currentProject?.path,
                        onHistory: { showingHistory = true }, onRevision: { id in
                            if let project = ProjectManager.shared.currentProject?.path,
                               let record = AIWorkspaceEdits.load(id: id, project: project) {
                                revisionPresentation = record
                            } else { revisionError = true }
                        }).equatable()
                    if !isInlineRecord {
                        composer
                            .zIndex(1)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: showingHistory && !reduceMotion ? geometry.size.width : 0)
                .opacity(reduceMotion && showingHistory ? 0 : 1)
                .allowsHitTesting(!showingHistory)
                .accessibilityHidden(showingHistory)

                historyPage
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: !showingHistory && !reduceMotion ? -geometry.size.width : 0)
                    .opacity(reduceMotion && !showingHistory ? 0 : 1)
                    .allowsHitTesting(showingHistory)
                    .accessibilityHidden(!showingHistory)
            }
            .animation(.smooth(duration: 0.28), value: showingHistory)
            .clipped()
        }
        .task(id: cliType) {
            if cliType == .chatgpt { await modelSettings.refreshModels() }
        }
        .sheet(isPresented: $showingPreview) { previewPage }
        .sheet(isPresented: $showingReferences) {
            if let project = ProjectManager.shared.currentProject?.path {
                AIContextPickerView(projectURL: project, onReviewRequested: AIAssistantViewModel.shared.prepareDraftAction)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aiWorkspaceFilesDidChange"))) { notification in
            if let id = notification.userInfo?["requestID"] as? UUID { completedWorkspaceRequests.insert(id) }
        }
        .sheet(item: $revisionPresentation) { AIWorkspaceRevisionView(record: $0) }
        .alert(L10n.get("revision.unavailable"), isPresented: $revisionError) { Button(L10n.get("common.close")) {} }
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.borderless).help(L10n.get(title)).accessibilityLabel(L10n.get(title))
    }

    // One persistent composer for both a new conversation and its follow-ups.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mode = AIChatMode.parse(inputText)?.mode ?? modelSettings.chatMode
            if modelSettings.hasChatModeTag || AIChatMode.parse(inputText) != nil {
                Button {
                    inputText = AIChatMode.parse(inputText)?.body ?? inputText
                    modelSettings.clearChatModeTag()
                    dismissedCommandDraft = inputText
                } label: {
                    Text(mode.command).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
                .help(L10n.get("ai.mode.removeTag"))
                .accessibilityLabel(mode.command + " · " + L10n.get("ai.mode.removeTag"))
            }
            if selectionState.isWaitingForSelection {
                SelectionInputView(options: selectionState.options) { onSelectionResponse?($0) }
            } else {
                MultiLineInputView(text: $inputText, contentHeight: $inputHeight,
                    placeholder: L10n.get(selectedCardId == nil ? "ai.chat.inputPlaceholder" : "ai.chat.continueConversation"),
                    isDisabled: isProcessing, minHeight: 48, maxHeight: 160,
                    onSubmit: { onSend(selectedCardId) },
                    onModeSelected: { mode in modelSettings.chatMode = mode },
                    focusRequest: inputFocusRequest)
                    .frame(height: inputHeight)
                    // An anchored in-window popover never becomes a key window or steals the caret.
                    .overlay(alignment: .bottomLeading) {
                        if !isProcessing && AIChatMode.completionRange(inputText) != nil && dismissedCommandDraft != inputText {
                            commandPopover
                                .padding(.bottom, inputHeight + 8)
                        }
                    }
                    .onChange(of: inputText) { _, value in
                        if AIChatMode.completionRange(value) == nil { dismissedCommandDraft = nil }
                    }
                HStack {
                    Button { showingContext = true } label: {
                        Label(contextCount == 0 ? L10n.get("ai.workspace.context") : "\(L10n.get("ai.workspace.context")) · \(contextCount)", systemImage: "paperclip")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.get("ai.workspace.context"))
                    .disabled(isProcessing)
                    .popover(isPresented: $showingContext, arrowEdge: .top) { contextPopover }
                    modelControls
                    Spacer(minLength: 2)
                    contextUsageButton
                    if isProcessing {
                        iconButton("ai.workspace.stop", "stop.circle.fill", action: onCancel)
                    } else {
                        iconButton("ai.chat.send", "arrow.up.circle.fill") { onSend(selectedCardId) }
                            .foregroundStyle(Color.accentColor)
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(10)
        // Match the manuscript surface without mixing in the lighter assistant backdrop.
        .background(AppColors.textEditorBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.top, 12)
        .padding(.leading, 4)
        // Match the native sidebar surface's inset from the window edges,
        // not the file list's 4pt padding inside that surface.
        .padding([.trailing, .bottom], 8)
    }

    private var modelControls: some View {
        Button { showingModelControls.toggle() } label: {
            HStack(spacing: 5) {
                Text(modelSettings.selectedModel(for: cliType)?.name ?? L10n.get("ai.model.choose"))
                    .lineLimit(1).truncationMode(.middle)
                Text(currentEffortLabel).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(isProcessing)
        .accessibilityLabel(L10n.get("ai.model.title") + " · " + L10n.get("ai.effort.title"))
        .popover(isPresented: $showingModelControls, arrowEdge: .top) {
            FocusRinglessPopover { modelPopover }
        }
    }

    private var commandPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AIChatMode.allCases, id: \.rawValue) { mode in
                Button {
                    let body = AIChatMode.removingTagsForSelection(inputText)
                    modelSettings.chatMode = mode
                    dismissedCommandDraft = inputText
                    inputText = body
                    inputFocusRequest += 1
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.command + " · " + mode.title).font(.callout)
                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
            }
        }
        .padding(6)
        .frame(maxWidth: 290)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private var effortSteps: [String] {
        modelSettings.selectedModel(for: cliType)?.efforts ?? []
    }
    private var effortIndex: Int {
        effortSteps.firstIndex(of: modelSettings.requestOptions(for: cliType).effort ?? "") ?? 0
    }
    private var currentEffortLabel: String {
        if let effort = modelSettings.requestOptions(for: cliType).effort { return effortLabel(effort) }
        return L10n.get("ai.effort.unavailable")
    }

    private var modelPopover: some View {
        VStack(spacing: 10) {
            Menu {
                ForEach(modelSettings.models(for: cliType)) { model in
                    Button { modelSettings.selectModel(model.id, for: cliType) } label: {
                        if modelSettings.selectedModel(for: cliType)?.id == model.id {
                            Label(model.name, systemImage: "checkmark")
                        } else { Text(model.name) }
                    }
                }
                if cliType == .chatgpt {
                    Divider()
                    Button(L10n.get(modelSettings.modelsError ? "ai.model.retry" : "ai.model.refresh")) {
                        Task { await modelSettings.refreshModels() }
                    }
                }
            } label: {
                Text(modelSettings.selectedModel(for: cliType)?.name ?? L10n.get("ai.model.choose"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            // Opening the popover moves keyboard focus to its first control. Keep that
            // focus available without drawing a selected outline around the model label.
            .focusEffectDisabled()
            .fixedSize()
            .accessibilityLabel(L10n.get("ai.model.title"))
            .disabled(modelSettings.modelsLoading)
            Slider(value: Binding(get: { Double(effortIndex) }, set: { value in
                guard !effortSteps.isEmpty else { return }
                let index = min(effortSteps.count - 1, max(0, Int(value.rounded())))
                modelSettings.selectEffort(effortSteps[index], for: cliType)
            }), in: 0...Double(max(1, effortSteps.count - 1)), step: 1)
            .focusEffectDisabled()
            .disabled(effortSteps.count < 2)
            .accessibilityLabel(L10n.get("ai.effort.title"))
            .accessibilityValue(currentEffortLabel)
            GeometryReader { geometry in
                let labelWidth = (currentEffortLabel as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11)
                ]).width
                let fraction = CGFloat(effortIndex) / CGFloat(max(1, effortSteps.count - 1))
                // Keep the label centered beneath the selected stop, clamping at the edges.
                let nodeX = 8 + fraction * max(0, geometry.size.width - 16)
                Text(currentEffortLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                    .position(x: min(max(labelWidth / 2, nodeX), geometry.size.width - labelWidth / 2),
                              y: geometry.size.height / 2)
            }
            .frame(height: 16)
        }
        .padding(14)
        .frame(width: 260)
        .disabled(isProcessing)
    }

    private func effortLabel(_ effort: String) -> String {
        let key = "ai.effort." + effort
        let value = L10n.get(key)
        return value == key ? effort.capitalized : value
    }

    private var latestContextUsage: AIContextUsage? {
        detailMessages.last(where: { $0.role == .assistant && !$0.isStreaming })?.usage
    }

    private var contextProgressLabel: String {
        latestContextUsage?.compactionProgress.map { "\(Int($0 * 100))%" }
            ?? L10n.get("ai.usage.unavailable")
    }

    private var contextUsageButton: some View {
        Button { showingUsage = true } label: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                if let progress = latestContextUsage?.compactionProgress {
                    Circle().trim(from: 0, to: progress)
                        .stroke(progress >= 0.9 ? Color.orange : Color.secondary,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: "questionmark").font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }.frame(width: 16, height: 16).padding(3)
        }
        .buttonStyle(.borderless)
        .help(L10n.get("ai.usage.compaction") + " · " + contextProgressLabel)
        .accessibilityLabel(L10n.get("ai.usage.title"))
        .accessibilityValue(contextProgressLabel)
        .popover(isPresented: $showingUsage, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.get("ai.usage.title")).font(.headline)
                if let usage = latestContextUsage {
                    LabeledContent(L10n.get("ai.usage.current"), value: usage.currentContextTokens?.formatted() ?? L10n.get("ai.usage.unavailable"))
                    LabeledContent(L10n.get("ai.usage.compaction"), value: usage.autoCompactTokenLimit?.formatted() ?? L10n.get("ai.usage.unavailable"))
                    Text(L10n.get("ai.usage.compactionNote")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent(L10n.get("ai.usage.input"), value: usage.inputTokens.formatted())
                    LabeledContent(L10n.get("ai.usage.cached"), value: usage.cachedTokens.formatted())
                    LabeledContent(L10n.get("ai.usage.output"), value: usage.outputTokens.formatted())
                    LabeledContent(L10n.get("ai.usage.limit"), value: usage.contextWindow?.formatted() ?? L10n.get("ai.usage.unavailable"))
                    Text(L10n.get("ai.usage.note")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.get("ai.usage.empty")).foregroundStyle(.secondary)
                }
            }.padding(16).frame(width: 290)
        }
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.get("ai.workspace.context")).font(.headline)
            Button(L10n.get("ai.context.title")) { showingContext = false; showingReferences = true }
            Toggle(L10n.get("ai.chat.attachCurrentDocument"), isOn: $includeCurrentDocument)
                .disabled(activeFile == nil)
            if includeCurrentDocument, let activeFile {
                Text(activeFile.title).font(.caption).lineLimit(2)
                Button(L10n.get("ai.chat.previewDocument")) {
                    documentPreview = onPreviewDocument()
                    showingContext = false
                    showingPreview = true
                }
            }
            if !conversationCards.isEmpty {
                Divider()
                Text(L10n.get("ai.workspace.references")).font(.subheadline.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(conversationCards) { card in
                            Toggle(isOn: Binding(get: { taggedCardIds.contains(card.id) }, set: { value in
                                if value { taggedCardIds.insert(card.id) } else { taggedCardIds.remove(card.id) }
                                onTagChanged?()
                            })) { Text(card.userMessage.content).lineLimit(2) }
                        }
                    }
                }.frame(maxHeight: 180)
            }
            Text(L10n.get("ai.chat.contextDisclosure")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 300)
    }

    private var historyPage: some View {
        VStack(spacing: 0) {
            LiquidGlassSegmentedControl(
                title: L10n.get("ai.inline.history"), selection: $historyKind,
                options: [0, 1, 2],
                label: { L10n.get(["ai.inline.allHistory", "ai.inline.chatHistory", "ai.inline.history"][$0]) }
            ).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            HStack(spacing: 8) {
                if isHistorySearchExpanded {
                    ToolbarSearchField(text: $historyQuery,
                        prompt: L10n.get("ai.workspace.searchHistory"),
                        onCancel: {
                            historyQuery = ""
                            isHistorySearchExpanded = false
                        })
                        .frame(maxWidth: 200)
                        .frame(height: 30)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    Button { isHistorySearchExpanded = true } label: {
                        Image(systemName: "magnifyingglass").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help(L10n.get("ai.workspace.searchHistory"))
                    .accessibilityLabel(L10n.get("ai.workspace.searchHistory"))
                }
                Spacer()
                iconButton("ai.workspace.new", "plus") {
                    selectedCardId = nil
                    showingHistory = false
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .animation(.smooth(duration: 0.22), value: isHistorySearchExpanded)
            List {
                ForEach(conversationCards.reversed().filter {
                    (historyQuery.isEmpty || $0.userMessage.content.localizedStandardContains(historyQuery) || $0.id.uuidString.localizedStandardContains(historyQuery) || ($0.userMessage.model?.localizedStandardContains(historyQuery) ?? false)) &&
                    (historyKind == 0 || ($0.userMessage.category == .inlineEdit ? historyKind == 2 : historyKind == 1))
                }) { card in
                    HStack {
                        Button {
                            selectedCardId = card.id
                            showingHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(card.userMessage.category.title,
                                      systemImage: card.userMessage.category == .inlineEdit ? "pencil.line" : "bubble.left.and.bubble.right")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("ID · " + card.id.uuidString.prefix(8))
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                if let model = card.userMessage.model {
                                    Text(model + (card.userMessage.reasoningEffort.map { " · " + effortLabel($0) } ?? ""))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(card.userMessage.content).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button(L10n.get("ai.history.copyID")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(card.id.uuidString, forType: .string)
                            }
                        }
                        Button(role: .destructive) { pendingDeletion = card.id } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(L10n.get("common.delete"))
                    }.padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(L10n.get("ai.workspace.deleteConfirm"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button(L10n.get("common.delete"), role: .destructive) {
                if let id = pendingDeletion { onDeleteCard?(id) }
                pendingDeletion = nil
            }
        }
    }

    private var previewPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: documentPreview?.name ?? L10n.get("ai.chat.previewDocument")) { showingPreview = false }
            Text(L10n.get("ai.chat.previewDocumentDescription")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(documentPreview?.content ?? L10n.get("ai.error.contextUnavailable"))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 560)
    }
}
