//
//  UserSettings.swift
//  TextlinkEditor
//
//  사용자 설정 관리 (비샌드박스 환경)
//

import Foundation
import SwiftUI

/// 앱 시작 시 동작 설정
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

/// 사용자 설정 관리자 (비샌드박스 환경)
@Observable
final class UserSettings {
    static let shared = UserSettings()

    private let defaults: UserDefaults

    // MARK: - Initialization

    private init() {
        // Preserve the legacy settings domain so the product rename keeps existing preferences.
        if let suite = UserDefaults(suiteName: "com.loreweave.settings") {
            self.defaults = suite
        } else {
            self.defaults = UserDefaults.standard
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let appLaunchBehavior = "appLaunchBehavior"
        static let appTheme = "appTheme"
        static let appLanguage = "appLanguage"
        static let autoSaveOption = "autoSaveOption"
        static let aiProvider = "aiProvider"
        static let aiApiKey = "aiApiKey"
        static let editorFontSize = "editorFontSize"
        static let editorLineSpacing = "editorLineSpacing"
        static let editorFontName = "editorFontName"
        static let editorLetterSpacing = "editorLetterSpacing"
        static let showLineNumbers = "showLineNumbers"
        static let defaultProjectLocation = "defaultProjectLocation"
        static let lastOpenedProject = "lastOpenedProject"
        static let recentProjectPaths = "recentProjectPaths"
        static let maxRecentProjects = "maxRecentProjects"
        static let aiAssistantPanelWidth = "aiAssistantPanelWidth"
        static let sidebarWidth = "sidebarWidth"
        static let appFontName = "appFontName"
        static let rememberCursorPosition = "rememberCursorPosition"
        // AI 어시스턴트 설정
        static let aiAssistantEnabled = "aiAssistantEnabled"
        static let aiAssistantCLIType = "aiAssistantCLIType"
        static let aiCLIPath = "aiCLIPath"
        /// disconnect 후 수동 CLI 선택 강제 플래그
        static let requireManualCLISelection = "requireManualCLISelection"
        /// AI CLI 터미널 모드 (대화형 프로세스 유지)
        static let aiTerminalMode = "aiTerminalMode"
    }

    // MARK: - 일반 설정

    /// 앱 시작 시 동작
    var appLaunchBehavior: AppLaunchBehavior {
        get {
            guard let raw = defaults.string(forKey: Keys.appLaunchBehavior),
                  let behavior = AppLaunchBehavior(rawValue: raw) else {
                return .showWelcome
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.appLaunchBehavior) }
    }

    /// 앱 테마
    var appTheme: AppTheme {
        get {
            guard let raw = defaults.string(forKey: Keys.appTheme),
                  let theme = AppTheme(rawValue: raw) else {
                return .system
            }
            return theme
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.appTheme) }
    }

    /// 앱 언어
    var appLanguage: AppLanguage {
        get {
            guard let raw = defaults.string(forKey: Keys.appLanguage),
                  let language = AppLanguage(rawValue: raw) else {
                return .system
            }
            return language
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.appLanguage)
            applyLanguageSetting(newValue)
        }
    }

    // MARK: - 자동 저장 설정

    /// 자동 저장 옵션
    var autoSaveOption: AutoSaveOption {
        get {
            guard let raw = defaults.string(forKey: Keys.autoSaveOption),
                  let option = AutoSaveOption(rawValue: raw) else {
                return .everyFiveMinutes
            }
            return option
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.autoSaveOption) }
    }

    // MARK: - AI 설정

    /// AI 제공자
    var aiProvider: AIProvider {
        get {
            guard let raw = defaults.string(forKey: Keys.aiProvider),
                  let provider = AIProvider(rawValue: raw) else {
                return .anthropic
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.aiProvider) }
    }

    /// AI API 키 (Keychain에 저장하는 것이 권장됨)
    var aiApiKey: String {
        get { defaults.string(forKey: Keys.aiApiKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.aiApiKey) }
    }

    // MARK: - 에디터 설정

    /// 에디터 폰트 크기
    var editorFontSize: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.editorFontSize) as? Double ?? 14.0) }
        set { defaults.set(Double(newValue), forKey: Keys.editorFontSize); NotificationCenter.default.post(name: .init("editorAppearanceDefaultsChanged"), object: nil) }
    }

    /// 에디터 표시 줄간격 비율 (100% = 1.0, 실제 배치는 LineSpacingOption에서 변환)
    var editorLineSpacing: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.editorLineSpacing) as? Double ?? 1.0) }
        set { defaults.set(Double(newValue), forKey: Keys.editorLineSpacing); NotificationCenter.default.post(name: .init("editorAppearanceDefaultsChanged"), object: nil) }
    }

    var editorLetterSpacing: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.editorLetterSpacing) as? Double ?? 0) }
        set {
            defaults.set(Double(newValue), forKey: Keys.editorLetterSpacing)
            NotificationCenter.default.post(name: .init("editorAppearanceDefaultsChanged"), object: nil)
        }
    }

    /// 에디터 폰트 이름
    var editorFontName: String {
        get { defaults.string(forKey: Keys.editorFontName) ?? "SF Pro" }
        set { defaults.set(newValue, forKey: Keys.editorFontName); NotificationCenter.default.post(name: .init("editorAppearanceDefaultsChanged"), object: nil) }
    }

    /// 줄 번호 표시
    var showLineNumbers: Bool {
        get { defaults.object(forKey: Keys.showLineNumbers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showLineNumbers) }
    }

    /// 파일 열 때 커서 위치 기억
    var rememberCursorPosition: Bool {
        get { defaults.object(forKey: Keys.rememberCursorPosition) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.rememberCursorPosition) }
    }

    // MARK: - 디렉토리 설정

    /// 기본 프로젝트 저장 위치
    var defaultProjectLocation: URL? {
        get {
            guard let path = defaults.string(forKey: Keys.defaultProjectLocation) else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
        set { defaults.set(newValue?.path, forKey: Keys.defaultProjectLocation) }
    }

    /// 기본 프로젝트 저장 위치 URL 가져오기 (하위 호환성)
    func getDefaultProjectLocation() -> URL? {
        return defaultProjectLocation
    }

    /// 기본 프로젝트 저장 위치 설정 (하위 호환성)
    func setDefaultProjectLocation(_ url: URL) -> Bool {
        defaultProjectLocation = url
        return true
    }

    // MARK: - 마지막으로 열린 프로젝트

    /// 마지막으로 열린 프로젝트 경로
    private var lastOpenedProjectPath: String? {
        get { defaults.string(forKey: Keys.lastOpenedProject) }
        set { defaults.set(newValue, forKey: Keys.lastOpenedProject) }
    }

    /// 마지막으로 열린 프로젝트가 저장되어 있는지 확인
    func hasLastOpenedProject() -> Bool {
        guard let path = lastOpenedProjectPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 마지막으로 열린 프로젝트 URL 가져오기
    func getLastOpenedProject() -> URL? {
        guard let path = lastOpenedProjectPath,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// 마지막으로 열린 프로젝트 저장
    func setLastOpenedProject(_ url: URL) {
        lastOpenedProjectPath = url.path
    }

    /// 마지막으로 열린 프로젝트 삭제
    func clearLastOpenedProject() {
        lastOpenedProjectPath = nil
    }

    func clearLastOpenedProject(ifMatching url: URL) {
        guard let path = lastOpenedProjectPath,
              URL(fileURLWithPath: path).standardizedFileURL.path == url.standardizedFileURL.path else { return }
        clearLastOpenedProject()
    }

    // MARK: - 최근 프로젝트

    /// 최대 최근 프로젝트 수
    var maxRecentProjects: Int {
        get { defaults.object(forKey: Keys.maxRecentProjects) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Keys.maxRecentProjects) }
    }

    /// 최근 프로젝트 경로 목록
    private var recentProjectPaths: [String] {
        get { defaults.array(forKey: Keys.recentProjectPaths) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: Keys.recentProjectPaths) }
    }

    /// 최근 프로젝트 URL 목록 가져오기
    func getRecentProjects() -> [URL] {
        let validPaths = recentProjectPaths.filter { FileManager.default.fileExists(atPath: $0) }

        // 유효하지 않은 경로가 있으면 정리
        if validPaths.count != recentProjectPaths.count {
            recentProjectPaths = validPaths
        }

        return validPaths.map { URL(fileURLWithPath: $0) }
    }

    /// 최근 프로젝트에 추가
    func addRecentProject(_ url: URL) {
        var paths = recentProjectPaths

        // 이미 존재하는 경우 제거 (중복 방지)
        paths.removeAll { $0 == url.path }

        // 맨 앞에 추가
        paths.insert(url.path, at: 0)

        // 최대 개수 제한
        if paths.count > maxRecentProjects {
            paths = Array(paths.prefix(maxRecentProjects))
        }

        recentProjectPaths = paths
    }

    /// 최근 프로젝트에서 제거
    func removeRecentProject(_ url: URL) {
        var paths = recentProjectPaths
        paths.removeAll { $0 == url.path }
        recentProjectPaths = paths
    }

    /// 최근 프로젝트 목록 초기화
    func clearRecentProjects() {
        recentProjectPaths = []
    }

    // MARK: - UI 레이아웃 설정

    /// AI 어시스턴트 패널 너비
    var aiAssistantPanelWidth: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.aiAssistantPanelWidth) as? Double ?? 320.0) }
        set { defaults.set(Double(newValue), forKey: Keys.aiAssistantPanelWidth) }
    }

    /// 사이드바 너비
    var sidebarWidth: CGFloat {
        get { CGFloat(defaults.object(forKey: Keys.sidebarWidth) as? Double ?? 220.0) }
        set { defaults.set(Double(newValue), forKey: Keys.sidebarWidth) }
    }

    // MARK: - AI 어시스턴트 설정

    /// AI 어시스턴트 활성화 여부
    var aiAssistantEnabled: Bool {
        get { defaults.object(forKey: Keys.aiAssistantEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.aiAssistantEnabled) }
    }

    /// 선택된 AI CLI 타입 (rawValue 저장)
    var aiAssistantCLIType: String {
        get { defaults.string(forKey: Keys.aiAssistantCLIType) ?? "" }
        set { defaults.set(newValue, forKey: Keys.aiAssistantCLIType) }
    }

    /// AI CLI 경로
    private var aiCLIPathString: String? {
        get { defaults.string(forKey: Keys.aiCLIPath) }
        set { defaults.set(newValue, forKey: Keys.aiCLIPath) }
    }

    /// AI CLI 경로 저장
    func setAICLIPath(_ url: URL) -> Bool {
        aiCLIPathString = url.path
        return true
    }

    /// AI CLI 경로 가져오기
    func getAICLIPath() -> URL? {
        guard let path = aiCLIPathString,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// AI CLI 경로가 저장되어 있는지 확인
    func hasAICLIPath() -> Bool {
        guard let path = aiCLIPathString else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// AI CLI 경로 삭제
    func clearAICLIPath() {
        aiCLIPathString = nil
    }

    /// disconnect 후 수동 CLI 선택 강제 플래그
    /// - disconnect 시 true로 설정
    /// - 사용자가 CLI 파일을 수동 선택하면 false로 리셋
    var requireManualCLISelection: Bool {
        get { defaults.object(forKey: Keys.requireManualCLISelection) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.requireManualCLISelection) }
    }

    /// AI CLI 터미널 모드 (대화형 프로세스 유지)
    /// - true: 대화형 터미널 모드 (프로세스 유지, stdin/stdout 스트림)
    /// - false: 단발성 프롬프트 모드 (매 질문마다 새 프로세스, --resume 사용)
    var aiTerminalMode: Bool {
        get { defaults.object(forKey: Keys.aiTerminalMode) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.aiTerminalMode) }
    }

    // MARK: - 앱 전역 폰트 설정

    /// 앱 전역 폰트 이름 (에디터와 줄번호 제외)
    var appFontName: String {
        get { defaults.string(forKey: Keys.appFontName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.appFontName) }
    }

    // MARK: - Private

    /// 언어 설정 적용
    private func applyLanguageSetting(_ language: AppLanguage) {
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .korean, .english, .japanese:
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    // MARK: - 설정 초기화

    /// 모든 설정을 기본값으로 초기화
    func resetAllSettings() {
        let allKeys = [
            Keys.appLaunchBehavior,
            Keys.appTheme,
            Keys.appLanguage,
            Keys.autoSaveOption,
            Keys.aiProvider,
            Keys.aiApiKey,
            EditorToolbarAppearance.iconSizeKey,
            EditorToolbarAppearance.numberSizeKey,
            EditorToolbarAppearance.heightKey,
            SidebarAppearance.textSizeKey,
            SidebarAppearance.iconSizeKey,
            Keys.editorFontSize,
            Keys.editorLineSpacing,
            Keys.editorFontName,
            Keys.editorLetterSpacing,
            Keys.showLineNumbers,
            Keys.rememberCursorPosition,
            Keys.defaultProjectLocation,
            Keys.lastOpenedProject,
            Keys.recentProjectPaths,
            Keys.maxRecentProjects,
            Keys.aiAssistantPanelWidth,
            Keys.sidebarWidth,
            Keys.appFontName,
            "panel.fontName",
            "panel.fontSize",
            "panel.lineSpacing",
            "panel.letterSpacing",
            Keys.aiAssistantEnabled,
            Keys.aiAssistantCLIType,
            Keys.aiCLIPath
        ]

        for key in allKeys {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .init("editorAppearanceDefaultsChanged"), object: nil)
    }
}

/// Shared defaults for the editor toolbar; separate from manuscript typography.
enum EditorToolbarAppearance {
    static let store = UserDefaults(suiteName: "com.loreweave.settings") ?? .standard
    static let iconSizeKey = "editorToolbar.iconSize"
    static let numberSizeKey = "editorToolbar.numberSize"
    static let heightKey = "editorToolbar.height"
    static let defaultIconSize = 11.0
    static let defaultNumberSize = 11.0
    static let defaultHeight = 32.0
    static let sizeRange = 10.0...20.0
    static let heightRange = 32.0...64.0
    static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Shared defaults for the project explorer's text and symbols.
enum SidebarAppearance {
    static let store = UserDefaults.standard
    static let textSizeKey = "sidebar.textSize"
    static let iconSizeKey = "sidebar.iconSize"
    static let defaultTextSize = 12.0
    static let defaultIconSize = 13.0
    static let textSizeRange: ClosedRange<Double> = 10...18
    static let iconSizeRange: ClosedRange<Double> = 10...20
    static func bounded(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
