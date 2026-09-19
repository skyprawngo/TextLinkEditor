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
