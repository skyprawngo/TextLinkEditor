import SwiftUI
import AppKit

/// Draft keystrokes do not rebuild the transcript. TextKit handles viewport reflow.
struct AIChatTranscript: View, Equatable {
    let messages: [AIMessage]
    let conversationID: UUID?
    let processing: Bool
    let completedRequests: Set<UUID>
    let project: URL?
    let onHistory: () -> Void
    let onRevision: (UUID) -> Void
    @AppStorage("panel.fontName") private var panelFontName = ""
    @AppStorage("panel.fontSize") private var panelFontSize = 13.0
    @AppStorage("panel.lineSpacing") private var panelLineSpacing = 3.0
    @AppStorage("panel.letterSpacing") private var panelLetterSpacing = 0.0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.conversationID == rhs.conversationID
            && lhs.processing == rhs.processing
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
            if messages.isEmpty {
                ContentUnavailableView {
                    Label(L10n.get("ai.workspace.new"), systemImage: "bubble.left.and.bubble.right")
                } description: { Text(L10n.get("ai.workspace.startHint")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AITranscriptScrollView(entries: messages.map { message in
                    let revision = message.role == .assistant && !message.isStreaming && message.category != .inlineEdit
                        && project.map { completedRequests.contains(message.id) || AIWorkspaceEdits.exists(id: message.id, project: $0) } == true
                    return .init(id: message.id, text: message.content, isUser: message.role == .user,
                        tag: nil, // Mode is draft/request metadata, not transcript content.
                        revisionTitle: revision ? L10n.get("revision.title") : nil)
                }, conversationID: conversationID, fontName: panelFontName, fontSize: panelFontSize,
                   lineSpacing: panelLineSpacing, letterSpacing: panelLetterSpacing,
                   processingText: processing ? L10n.get("ai.chat.streaming") : nil,
                   onRevision: onRevision,
                   onComment: { AIAssistantViewModel.shared.collaboration.submitComment($0) },
                   commentTitle: L10n.get("collaboration.fromChat"), copyTitle: L10n.get("common.copy"),
                   projectURL: project,
                   onOpenFile: { EditorTabManager.shared.openFile(FileSystemItem(url: $0, isDirectory: false)) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .clipped()
    }
}
