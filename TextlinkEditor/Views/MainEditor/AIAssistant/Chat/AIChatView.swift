//
//  AIChatView.swift
//  TextlinkEditor
//
//  대화 작업 공간: 기록 탐색과 첨부 선택은 보조 화면, 입력은 단일 AppKit 뷰.
//

import SwiftUI
import AppKit

// MARK: - 대화 카드 모델

/// 사용자 질문 + AI 답변을 하나의 카드로 묶는 모델
/// - 세션 뷰 (카드 목록): 각 카드는 독립적인 대화 세션을 나타냄
/// - 채팅 뷰 (카드 내부): 해당 카드의 세션 ID를 사용하여 대화 계속
struct ConversationCard: Identifiable, Equatable {
    let id: UUID
    let userMessage: AIMessage
    var assistantMessage: AIMessage?
    var isTaggedForContext: Bool = false
    /// CLI 세션 ID (카드별 대화 연속성 유지용)
    var cliSessionId: String?

    init(userMessage: AIMessage, assistantMessage: AIMessage? = nil, cliSessionId: String? = nil) {
        self.id = userMessage.conversationId ?? userMessage.id
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.cliSessionId = cliSessionId
    }

    var isStreaming: Bool {
        assistantMessage?.isStreaming ?? false
    }

    static func == (lhs: ConversationCard, rhs: ConversationCard) -> Bool {
        lhs.id == rhs.id &&
        lhs.assistantMessage?.content == rhs.assistantMessage?.content &&
        lhs.isTaggedForContext == rhs.isTaggedForContext &&
        lhs.cliSessionId == rhs.cliSessionId
    }
}

// MARK: - 다중 줄 입력 뷰

/// 다중 줄 입력을 지원하는 텍스트 입력 뷰 (Shift+Enter로 줄바꿈, Enter로 전송)
/// 텍스트 내용에 따라 높이가 자동으로 확장됩니다 (minHeight ~ maxHeight)
struct MultiLineInputView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let placeholder: String
    let isDisabled: Bool
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void

    init(
        text: Binding<String>,
        contentHeight: Binding<CGFloat>,
        placeholder: String,
        isDisabled: Bool,
        minHeight: CGFloat = 32,
        maxHeight: CGFloat = 120,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self._contentHeight = contentHeight
        self.placeholder = placeholder
        self.isDisabled = isDisabled
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = InputScrollView()
        let textView = InputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: minHeight))

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = NSColor(AppColors.textPrimary)
        textView.insertionPointColor = NSColor(AppColors.accent)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isRichText = false
        textView.allowsUndo = true

        context.coordinator.textView = textView

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // 초기 높이 계산
        DispatchQueue.main.async {
            context.coordinator.updateContentHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.parent = self
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            textView.undoManager?.removeAllActions()
            // 텍스트가 외부에서 변경된 경우 높이 재계산
            DispatchQueue.main.async {
                context.coordinator.updateContentHeight()
            }
        }

        textView.isEditable = !isDisabled
        context.coordinator.updatePlaceholder()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineInputView
        weak var textView: NSTextView?
        private var placeholderLabel: NSTextField?

        init(_ parent: MultiLineInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder()
            updateContentHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if textView.hasMarkedText() { return false }
                if !parent.text.isEmpty && !parent.isDisabled {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }

        /// 텍스트 내용에 따른 높이 계산 및 업데이트
        func updateContentHeight() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // 레이아웃 강제 수행
            layoutManager.ensureLayout(for: textContainer)

            // 텍스트 콘텐츠의 실제 높이 계산
            let usedRect = layoutManager.usedRect(for: textContainer)
            let insetHeight = textView.textContainerInset.height * 2

            // 계산된 높이 (최소/최대 범위 내)
            let calculatedHeight = usedRect.height + insetHeight
            let clampedHeight = min(max(calculatedHeight, parent.minHeight), parent.maxHeight)

            // 높이가 변경된 경우에만 업데이트
            if abs(parent.contentHeight - clampedHeight) > 0.5 {
                parent.contentHeight = clampedHeight
            }

            // 스크롤 가능 여부 설정 (최대 높이에 도달한 경우)
            if let scrollView = textView.enclosingScrollView {
                scrollView.hasVerticalScroller = calculatedHeight > parent.maxHeight
            }
        }

        func updatePlaceholder() {
            guard let textView = textView else { return }

            if placeholderLabel == nil {
                let label = InputPlaceholderLabel(labelWithString: parent.placeholder)
                label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                label.textColor = NSColor.placeholderTextColor
                label.backgroundColor = .clear
                label.isBordered = false
                label.isEditable = false
                label.isSelectable = false
                label.translatesAutoresizingMaskIntoConstraints = false

                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 4)
                ])

                placeholderLabel = label
            }

            placeholderLabel?.stringValue = parent.placeholder
            placeholderLabel?.isHidden = !textView.string.isEmpty
        }
    }
}

private final class InputPlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        text.minSize = NSSize(width: 0, height: max(1, contentSize.height))
        text.setFrameSize(NSSize(width: width, height: max(contentSize.height, text.frame.height)))
        text.textContainer?.containerSize.width = width
    }
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? NSTextView { window?.makeFirstResponder(text) }
        super.mouseDown(with: event)
    }
}

private class InputTextView: NSTextView {
    // NSTextView owns composed-character edits, IME groups, selection replacement, and delegate notifications.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
}

// MARK: - 대화 카드 뷰
// Conversation summaries are presented in the history sheet.

// MARK: - 선택 옵션 입력 뷰 (키보드 네비게이션 지원)

/// CLI 대화형 선택 UI - 방향키로 옵션 변경, 엔터로 선택 확정
struct SelectionInputView: View {
    let options: [CLISelectionOption]
    let onSelect: (Int) -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 안내 텍스트
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.caption)
                    .foregroundStyle(AppColors.accent)
                Text(L10n.get("ai.chat.selectOption"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer()

                // 키보드 힌트
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(L10n.get("ai.chat.arrowKeys"))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                    Text("⏎")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(L10n.get("ai.chat.enterKey"))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            // 선택 옵션 버튼들
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    let isHighlighted = index == selectedIndex

                    Button(action: {
                        onSelect(option.id)
                    }) {
                        HStack(spacing: 10) {
                            // 번호 배지
                            Text("\(option.id)")
                                .font(.system(.caption, design: .monospaced).bold())
                                .foregroundStyle(isHighlighted ? AppColors.background : AppColors.accent)
                                .frame(width: 24, height: 24)
                                .background(isHighlighted ? AppColors.accent : AppColors.controlBackground)
                                .clipShape(Circle())

                            // 옵션 텍스트
                            Text(option.label)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AppColors.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer()

                            // 현재 선택 표시
                            if isHighlighted {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(isHighlighted ? AppColors.accent.opacity(0.1) : AppColors.controlBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isHighlighted ? AppColors.accent : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(AppColors.textEditorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 25)
        .focusable()
        .focused($isFocused)
        .onAppear {
            // 첫 번째 옵션 또는 현재 선택된 옵션으로 초기화
            if let currentIndex = options.firstIndex(where: { $0.isSelected }) {
                selectedIndex = currentIndex
            } else {
                selectedIndex = 0
            }
            // 포커스 설정
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            confirmSelection()
            return .handled
        }
        .onKeyPress(keys: [.init("1"), .init("2"), .init("3"), .init("4"), .init("5"), .init("6"), .init("7"), .init("8"), .init("9")]) { press in
            // 숫자 키로 직접 선택
            if let digit = Int(press.characters), digit > 0 && digit <= options.count {
                if let option = options.first(where: { $0.id == digit }) {
                    onSelect(option.id)
                    return .handled
                }
            }
            return .ignored
        }
    }

    private func moveSelection(by offset: Int) {
        let newIndex = selectedIndex + offset
        if newIndex >= 0 && newIndex < options.count {
            selectedIndex = newIndex
        }
    }

    private func confirmSelection() {
        guard selectedIndex >= 0 && selectedIndex < options.count else { return }
        let option = options[selectedIndex]
        onSelect(option.id)
    }
}

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
    @State private var dismissedCommandDraft: String?
    @State private var showingModelControls = false
    @State private var composerHeight: CGFloat = 118
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
    @State private var historyKind = 0
    @State private var pendingDeletion: UUID?
    @State private var confirmingClear = false
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
                ZStack(alignment: .bottom) {
                    AIChatTranscript(messages: detailMessages, conversationID: selectedCardId,
                        processing: isProcessing, bottomInset: isInlineRecord ? 0 : composerHeight,
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
                            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: {
                                if composerHeight != $0 { composerHeight = $0 }
                            }
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
            if mode != .conversation {
                Button {
                    inputText = AIChatMode.parse(inputText)?.body ?? inputText
                    modelSettings.chatMode = .conversation
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
                    onSubmit: { onSend(selectedCardId) })
                    .frame(height: inputHeight)
                    .popover(isPresented: Binding(
                        get: { !isProcessing && AIChatMode.completionRange(inputText) != nil && dismissedCommandDraft != inputText },
                        set: { if !$0 { dismissedCommandDraft = inputText } }
                    ), arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(AIChatMode.allCases, id: \.rawValue) { mode in
                                Button {
                                    let body = AIChatMode.removingTagsForSelection(inputText)
                                    modelSettings.chatMode = mode
                                    dismissedCommandDraft = inputText
                                    inputText = body
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(mode.command + " · " + mode.title).font(.callout)
                                        Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(6).frame(width: 290)
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
        .background(AppColors.textEditorBackground, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(12)
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
        .popover(isPresented: $showingModelControls, arrowEdge: .top) { modelPopover }
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

    private var contextUsageButton: some View {
        Button { showingUsage = true } label: {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(L10n.get("ai.usage.title"))
        .accessibilityLabel(L10n.get("ai.usage.title"))
        .popover(isPresented: $showingUsage, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.get("ai.usage.title")).font(.headline)
                if let usage = detailMessages.last(where: { $0.role == .assistant })?.usage {
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
            HStack {
                Text(L10n.get("ai.workspace.history")).font(.headline)
                Spacer()
                iconButton("ai.workspace.new", "plus") {
                    selectedCardId = nil
                    showingHistory = false
                }
            }.padding(16)
            TextField(L10n.get("ai.workspace.searchHistory"), text: $historyQuery)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            Picker(L10n.get("ai.inline.history"), selection: $historyKind) {
                Text(L10n.get("ai.inline.allHistory")).tag(0)
                Text(L10n.get("ai.inline.chatHistory")).tag(1)
                Text(L10n.get("ai.inline.history")).tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
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
            HStack {
                Button(L10n.get("ai.chat.clearHistory"), role: .destructive) { confirmingClear = true }
                    .disabled(messages.isEmpty)
                Spacer()
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(L10n.get("ai.workspace.deleteConfirm"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button(L10n.get("common.delete"), role: .destructive) {
                if let id = pendingDeletion { onDeleteCard?(id) }
                pendingDeletion = nil
            }
        }
        .confirmationDialog(L10n.get("ai.workspace.clearConfirm"), isPresented: $confirmingClear) {
            Button(L10n.get("ai.chat.clearHistory"), role: .destructive, action: onClearHistory)
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

/// Draft keystrokes must not invalidate the lazy transcript's measured row heights.
/// Real messages, streaming updates, revisions, and composer line growth still update it.
private struct AIChatTranscript: View, Equatable {
    let messages: [AIMessage]
    let conversationID: UUID?
    let processing: Bool
    let bottomInset: CGFloat
    let completedRequests: Set<UUID>
    let project: URL?
    let onHistory: () -> Void
    let onRevision: (UUID) -> Void
    @State private var followsResponse = true
    @AppStorage("panel.fontName") private var panelFontName = ""
    @AppStorage("panel.fontSize") private var panelFontSize = 13.0
    @AppStorage("panel.lineSpacing") private var panelLineSpacing = 3.0
    @AppStorage("panel.letterSpacing") private var panelLetterSpacing = 0.0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.conversationID == rhs.conversationID
            && lhs.processing == rhs.processing && lhs.bottomInset == rhs.bottomInset
            && lhs.completedRequests == rhs.completedRequests && lhs.project == rhs.project
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onHistory) { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).help(L10n.get("ai.workspace.history"))
                    .accessibilityLabel(L10n.get("ai.workspace.history"))
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    // Message heights vary widely. Exact layout avoids the feedback between
                    // lazy height estimates, bottom anchoring and selectable-text overlays.
                    VStack(alignment: .leading, spacing: 20) {
                        if messages.isEmpty {
                            ContentUnavailableView {
                                Label(L10n.get("ai.workspace.new"), systemImage: "bubble.left.and.bubble.right")
                            } description: { Text(L10n.get("ai.workspace.startHint")) }
                                .padding(.top, 32)
                        }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                if message.role == .user, let rawMode = message.chatMode,
                                   let mode = AIChatMode(rawValue: rawMode) {
                                    Text(mode.command).font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                }
                                Text(message.content).textSelection(.enabled)
                                    .font(panelFontName.isEmpty || panelFontName == "SF Pro" || panelFontName == "System"
                                          ? .system(size: panelFontSize) : .custom(panelFontName, size: panelFontSize))
                                    .lineSpacing(panelLineSpacing)
                                    .tracking(panelLetterSpacing)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if message.role == .assistant, !message.isStreaming, message.category != .inlineEdit,
                                   let project, completedRequests.contains(message.id) || AIWorkspaceEdits.exists(id: message.id, project: project) {
                                    Button(L10n.get("revision.title")) { onRevision(message.id) }.buttonStyle(.borderless)
                                }
                            }
                            .padding(message.role == .user ? 12 : 0)
                            .background(message.role == .user ? Color.primary.opacity(0.05) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button(L10n.get("collaboration.fromChat")) {
                                    AIAssistantViewModel.shared.collaboration.submitComment(message.content)
                                }
                                Button(L10n.get("common.copy")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                }
                            }
                        }
                        if processing {
                            HStack { ProgressView().controlSize(.small); Text(L10n.get("ai.chat.streaming")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: bottomInset).id("bottom")
                    }.padding(14)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 64
                } action: { _, nearBottom in followsResponse = nearBottom }
                .onChange(of: conversationID) { _, _ in followsResponse = true; proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.last?.content) { _, _ in
                    if followsResponse { proxy.scrollTo("bottom") }
                }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom") }
            }
        }
    }
}
