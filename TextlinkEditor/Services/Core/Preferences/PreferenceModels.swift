import SwiftUI

enum AppLaunchBehavior: String, CaseIterable, Identifiable {
    case showWelcome = "showWelcome"
    case openLastProject = "openLastProject"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showWelcome: return L10n.get("settings.launch.showWelcome")
        case .openLastProject: return L10n.get("settings.launch.openLastProject")
        }
    }
}

/// 앱 테마 설정
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    case opaque = "opaque"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.get("settings.theme.system")
        case .light: return L10n.get("settings.theme.light")
        case .dark: return L10n.get("settings.theme.dark")
        case .opaque: return L10n.get("settings.theme.opaque")
        }
    }
}

/// AI 제공자 설정
enum AIProvider: String, CaseIterable, Identifiable {
    case openai = "openai"
    case anthropic = "anthropic"
    case local = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .local: return L10n.get("settings.ai.local")
        }
    }
}

/// 앱 언어 설정
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case korean = "ko"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.get("settings.language.system")
        case .korean: return "한국어"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
}

/// 자동 저장 옵션
enum AutoSaveOption: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case everyFiveMinutes = "5min"
    case everyTenMinutes = "10min"
    case onTabChange = "tabChange"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: return L10n.get("settings.autoSave.disabled")
        case .everyFiveMinutes: return L10n.get("settings.autoSave.everyFiveMinutes")
        case .everyTenMinutes: return L10n.get("settings.autoSave.everyTenMinutes")
        case .onTabChange: return L10n.get("settings.autoSave.onTabChange")
        }
    }

    /// 자동 저장 간격 (초). disabled와 onTabChange는 0 반환 (타이머 사용 안 함)
    var intervalSeconds: Int {
        switch self {
        case .disabled: return 0
        case .everyFiveMinutes: return 300
        case .everyTenMinutes: return 600
        case .onTabChange: return 0
        }
    }

    /// 자동 저장이 활성화되어 있는지 여부
    var isEnabled: Bool {
        self != .disabled
    }
}
