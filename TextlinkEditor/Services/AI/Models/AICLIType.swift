//
//  AICLIType.swift
//  TextlinkEditor
//
//  AI CLI 타입 정의
//

import Foundation

/// 지원하는 AI CLI 타입
enum AICLIType: String, CaseIterable, Identifiable {
    case claude = "claude"
    case chatgpt = "chatgpt"

    var id: String { rawValue }

    /// 표시 이름
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT (Codex)"
        }
    }

    /// CLI 명령어 이름
    var commandName: String {
        switch self {
        case .claude: return "claude"
        case .chatgpt: return "codex"
        }
    }

    /// 아이콘 이미지 이름 (Assets 카탈로그)
    var iconImageName: String {
        switch self {
        case .claude: return "claude_icon"
        case .chatgpt: return "chatgpt_icon"
        }
    }

    /// 아이콘 (SF Symbols) - 폴백용
    var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right"
        }
    }

    /// 공식 설치 페이지 URL
    var installPageURL: URL? {
        switch self {
        case .claude:
            return URL(string: "https://claude.ai/code")
        case .chatgpt:
            return URL(string: "https://developers.openai.com/codex/cli/")
        }
    }

    /// 설치 문서 페이지 URL (설치 방법 안내)
    var setupDocsURL: URL? {
        switch self {
        case .claude:
            return URL(string: "https://code.claude.com/docs/ko/setup")
        case .chatgpt:
            return URL(string: "https://developers.openai.com/codex/cli/")
        }
    }

    /// 공식 설치 스크립트 (있는 경우)
    var installScript: String? {
        switch self {
        case .claude:
            // Claude CLI 공식 설치 명령어 (native installer)
            return "curl -fsSL https://claude.ai/install.sh | bash"
        case .chatgpt:
            // ChatGPT CLI는 별도 설치 스크립트가 없음
            return nil
        }
    }

    /// Homebrew 설치 명령어 (있는 경우)
    var homebrewFormula: String? {
        switch self {
        case .claude:
            return nil // npm으로 설치
        case .chatgpt:
            return nil
        }
    }

    /// CLI가 설치될 일반적인 경로들
    var possiblePaths: [String] {
        switch self {
        case .claude:
            return [
                "~/.local/bin/claude",  // 공식 설치 기본 경로
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "~/.npm-global/bin/claude",
                "/usr/bin/claude"
            ]
        case .chatgpt:
            return [
                "~/.local/bin/codex",
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/bin/codex"
            ]
        }
    }
}

struct AIModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let efforts: [String]
    var isDefault = false
    var defaultEffort: String? = nil
    static func parse(_ value: [String: Any]) -> Self? {
        guard let id = value["model"] as? String, !id.isEmpty, value["hidden"] as? Bool != true else { return nil }
        return Self(id: id, name: value["displayName"] as? String ?? id,
                    efforts: (value["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }, isDefault: value["isDefault"] as? Bool ?? false, defaultEffort: value["defaultReasoningEffort"] as? String)
    }
}

struct AIRequestOptions {
    var model: String?
    var effort: String?
    var readsProjectFiles = false
    var allowsSteering = false
    func arguments(for type: AICLIType) -> [String] {
        var result: [String] = []
        if let model { result += ["--model", model] }
        if let effort {
            if type == .chatgpt {
                // JSON string escaping is also valid for these TOML basic string values.
                let value = String(decoding: try! JSONEncoder().encode(effort), as: UTF8.self)
                result += ["-c", "model_reasoning_effort=" + value]
            } else { result += ["--effort", effort] }
        }
        return result
    }
}
