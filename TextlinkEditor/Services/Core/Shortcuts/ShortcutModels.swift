import SwiftUI
import AppKit

// MARK: - Shortcut Action

/// 단축키로 실행할 수 있는 액션 목록
struct ShortcutAction: RawRepresentable, Hashable, Identifiable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    static let newFile = Self(rawValue: "file.new")
    static let copyPath = Self(rawValue: "file.copyPath")
    static let copyRelativePath = Self(rawValue: "file.copyRelativePath")
    static let renameItem = Self(rawValue: "file.renameItem")
    static let newFolder = Self(rawValue: "file.newFolder")
    static let openFile = Self(rawValue: "file.open")
    static let save = Self(rawValue: "file.save")
    static let saveAs = Self(rawValue: "file.saveAs")
    static let closeTab = Self(rawValue: "file.closeTab")
    static let closeAllTabs = Self(rawValue: "file.closeAllTabs")
    static let undo = Self(rawValue: "edit.undo")
    static let redo = Self(rawValue: "edit.redo")
    static let cut = Self(rawValue: "edit.cut")
    static let copy = Self(rawValue: "edit.copy")
    static let paste = Self(rawValue: "edit.paste")
    static let selectAll = Self(rawValue: "edit.selectAll")
    static let find = Self(rawValue: "edit.find")
    static let findAndReplace = Self(rawValue: "edit.findAndReplace")
    static let moveLineUp = Self(rawValue: "edit.moveLineUp")
    static let moveLineDown = Self(rawValue: "edit.moveLineDown")
    static let duplicateLineUp = Self(rawValue: "edit.duplicateLineUp")
    static let duplicateLineDown = Self(rawValue: "edit.duplicateLineDown")
    static let deleteWordBackward = Self(rawValue: "edit.deleteWordBackward")
    static let deleteToLineStart = Self(rawValue: "edit.deleteToLineStart")
    static let toggleSidebar = Self(rawValue: "view.toggleSidebar")
    static let toggleAIPanel = Self(rawValue: "view.toggleAIPanel")
    static let zoomIn = Self(rawValue: "view.zoomIn")
    static let zoomOut = Self(rawValue: "view.zoomOut")
    static let resetZoom = Self(rawValue: "view.resetZoom")
    static let nextTab = Self(rawValue: "tab.next")
    static let previousTab = Self(rawValue: "tab.previous")
    static let goToTab1 = Self(rawValue: "tab.goTo1")
    static let goToTab2 = Self(rawValue: "tab.goTo2")
    static let goToTab3 = Self(rawValue: "tab.goTo3")
    static let goToTab4 = Self(rawValue: "tab.goTo4")
    static let goToTab5 = Self(rawValue: "tab.goTo5")
    static let goToTab6 = Self(rawValue: "tab.goTo6")
    static let goToTab7 = Self(rawValue: "tab.goTo7")
    static let goToTab8 = Self(rawValue: "tab.goTo8")
    static let goToTab9 = Self(rawValue: "tab.goTo9")
    static let aiContinueWriting = Self(rawValue: "ai.continueWriting")
    static let aiRefine = Self(rawValue: "ai.refine")
    static let aiSummarize = Self(rawValue: "ai.summarize")
    static let openProject = Self(rawValue: "project.open")
    static let newProject = Self(rawValue: "project.new")
    static let refreshProject = Self(rawValue: "project.refresh")

    var id: String { rawValue }
    var category: ShortcutCategory {
        if let tool = EditorToolRegistry.definition(rawValue) { return ShortcutCategory(rawValue: tool.category.rawValue) ?? .edit }
        return ShortcutCategory(rawValue: String(rawValue.split(separator: ".").first ?? "edit")) ?? .edit
    }
    var displayName: String { L10n.get(EditorToolRegistry.definition(rawValue)?.titleKey ?? "shortcut.\(rawValue)") }
}

// MARK: - Shortcut Category

/// 단축키 카테고리
enum ShortcutCategory: String, CaseIterable, Identifiable {
    case file
    case edit
    case view
    case tab
    case ai
    case project

    var id: String { rawValue }

    var displayName: String {
        L10n.get("shortcut.category.\(rawValue)")
    }
}

// MARK: - Modifier Keys

/// 수정자 키
struct ModifierKeys: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = ModifierKeys(rawValue: 1 << 0)
    static let shift = ModifierKeys(rawValue: 1 << 1)
    static let option = ModifierKeys(rawValue: 1 << 2)
    static let control = ModifierKeys(rawValue: 1 << 3)

    /// SwiftUI EventModifiers로 변환
    var eventModifiers: SwiftUI.EventModifiers {
        var modifiers: SwiftUI.EventModifiers = []
        if contains(.command) { modifiers.insert(.command) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var appKitModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// 표시용 문자열 (예: "⌘⇧")
    var displayString: String {
        var symbols: [String] = []
        if contains(.control) { symbols.append("⌃") }
        if contains(.option) { symbols.append("⌥") }
        if contains(.shift) { symbols.append("⇧") }
        if contains(.command) { symbols.append("⌘") }
        return symbols.joined()
    }
}

// MARK: - Keyboard Shortcut Binding

/// 단축키 바인딩 (액션과 키 조합)
struct ShortcutBinding: Codable, Identifiable, Equatable {
    var id: String { action.rawValue }

    let action: ShortcutAction
    var key: String  // 예: "n", "s", "f1", "tab"
    var modifiers: ModifierKeys
    var isEnabled: Bool

    /// 표시용 문자열 (예: "⌘N")
    var displayString: String {
        if key.isEmpty { return "—" }
        let keyDisplay = key.count == 1 ? key.uppercased() : key.capitalized
        return "\(modifiers.displayString)\(keyDisplay)"
    }

    /// AppKit menu items use characters rather than `KeyEquivalent` values.
    var menuKeyEquivalent: String? {
        guard isEnabled else { return nil }
        switch key.lowercased() {
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete", "backspace": return "\u{8}"
        case "escape", "esc": return "\u{1b}"
        default: return key.count == 1 ? key.lowercased() : nil
        }
    }

    /// SwiftUI KeyboardShortcut으로 변환
    var keyboardShortcut: KeyboardShortcut? {
        guard isEnabled, let keyEquivalent = KeyEquivalent(key) else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
    }
}

// MARK: - KeyEquivalent Extension

extension KeyEquivalent {
    init?(_ string: String) {
        guard !string.isEmpty else { return nil }

        // 특수 키 처리
        switch string.lowercased() {
        case "return", "enter": self = .return
        case "tab": self = .tab
        case "space": self = .space
        case "delete", "backspace": self = .delete
        case "escape", "esc": self = .escape
        case "up": self = .upArrow
        case "down": self = .downArrow
        case "left": self = .leftArrow
        case "right": self = .rightArrow
        case "home": self = .home
        case "end": self = .end
        case "pageup": self = .pageUp
        case "pagedown": self = .pageDown
        default:
            // 단일 문자
            if string.count == 1, let char = string.lowercased().first {
                self = KeyEquivalent(char)
            } else {
                return nil
            }
        }
    }
}
