//
//  AIMessage.swift
//  TextlinkEditor
//
//  채팅 메시지 모델
//

import Foundation

/// 채팅 메시지 역할
enum AIMessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

enum AIConversationCategory: String, Codable, CaseIterable {
    case chat, inlineEdit, commitMessage
    var title: String {
        L10n.get(self == .chat ? "ai.inline.chatHistory" : self == .inlineEdit ? "ai.inline.history" : "git.aiModel")
    }
}

/// 채팅 메시지
struct AIMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: AIMessageRole
    let content: String
    let timestamp: Date
    var isStreaming: Bool
    var conversationId: UUID?
    var outcome: String?
    var kind: String?
    var usage: AIContextUsage?
    var provider: String?
    var model: String?
    var reasoningEffort: String?
    var chatMode: String?
    var category: AIConversationCategory { kind == "inlineEdit" ? .inlineEdit : .chat }

    init(
        id: UUID = UUID(),
        role: AIMessageRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        conversationId: UUID? = nil,
        outcome: String? = nil,
        kind: String? = nil,
        usage: AIContextUsage? = nil,
        provider: String? = nil, model: String? = nil, reasoningEffort: String? = nil, chatMode: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.conversationId = conversationId
        self.outcome = outcome
        self.kind = kind
        self.usage = usage
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.chatMode = chatMode
    }

    static func == (lhs: AIMessage, rhs: AIMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming && lhs.conversationId == rhs.conversationId && lhs.outcome == rhs.outcome && lhs.kind == rhs.kind && lhs.usage == rhs.usage && lhs.provider == rhs.provider && lhs.model == rhs.model && lhs.reasoningEffort == rhs.reasoningEffort && lhs.chatMode == rhs.chatMode
    }
}

/// CLI 대화형 선택 옵션
/// Claude CLI가 사용자에게 선택지를 제공할 때 파싱된 옵션
struct CLISelectionOption: Identifiable, Equatable {
    let id: Int
    let label: String
    let isSelected: Bool

    init(id: Int, label: String, isSelected: Bool = false) {
        self.id = id
        self.label = label
        self.isSelected = isSelected
    }
}

/// CLI 선택 상태
struct CLISelectionState: Equatable {
    var options: [CLISelectionOption]
    var isWaitingForSelection: Bool

    init(options: [CLISelectionOption] = [], isWaitingForSelection: Bool = false) {
        self.options = options
        self.isWaitingForSelection = isWaitingForSelection
    }

    static let empty = CLISelectionState()
}

/// 채팅 세션 (프로젝트별 저장용)
struct AIChatSession: Codable {
    let id: UUID
    let projectPath: String
    let cliType: String
    var messages: [AIMessage]
    let createdAt: Date
    var updatedAt: Date

    /// CLI 세션 ID (대화 연속성 유지용)
    /// Claude CLI: --resume 옵션에 사용
    var cliSessionId: String?

    init(
        id: UUID = UUID(),
        projectPath: String,
        cliType: String,
        messages: [AIMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cliSessionId: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.cliType = cliType
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliSessionId = cliSessionId
    }
}

/// Reported turn totals, not an estimate of the current context-window occupancy.
struct AIContextUsage: Codable, Equatable {
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
    let contextWindow: Int?
    var currentContextTokens: Int? = nil
    var autoCompactTokenLimit: Int? = nil
    var compactionProgress: Double? {
        guard let currentContextTokens, currentContextTokens >= 0,
              let autoCompactTokenLimit, autoCompactTokenLimit > 0 else { return nil }
        return min(1, Double(currentContextTokens) / Double(autoCompactTokenLimit))
    }
    static func parse(_ event: [String: Any]) -> Self? {
        guard let usage = event["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int else { return nil }
        let claude = event["type"] as? String == "result"
        let cached = (usage[claude ? "cache_read_input_tokens" : "cached_input_tokens"] as? Int) ?? 0
        let created = claude ? (usage["cache_creation_input_tokens"] as? Int ?? 0) : 0
        let models = event["modelUsage"] as? [String: [String: Any]]
        let capacity = models?.count == 1 ? models?.values.first?["contextWindow"] as? Int : nil
        return Self(inputTokens: max(0, input + (claude ? cached + created : 0)), cachedTokens: max(0, cached),
                    outputTokens: max(0, usage["output_tokens"] as? Int ?? 0), contextWindow: capacity)
    }
}
