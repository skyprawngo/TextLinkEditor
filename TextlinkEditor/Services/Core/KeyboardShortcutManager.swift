//
//  KeyboardShortcutManager.swift
//  TextlinkEditor
//
//  키보드 단축키 관리 서비스 (샌드박스 위치에 JSON 파일로 저장)
//

import Foundation
import SwiftUI
import Carbon.HIToolbox

// MARK: - Keyboard Shortcut Manager

@Observable
final class KeyboardShortcutManager {
    static let shared = KeyboardShortcutManager()

    /// 현재 단축키 바인딩 목록
    private(set) var bindings: [ShortcutBinding] = []

    /// 단축키 파일 경로
    private var shortcutsFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
    // Legacy storage identity retained for existing user data after the product rename.
        let appFolder = appSupport.appendingPathComponent("Loreweave", isDirectory: true)

        // 폴더가 없으면 생성
        if !FileManager.default.fileExists(atPath: appFolder.path) {
            try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }

        return appFolder.appendingPathComponent("shortcuts.json")
    }

    private var registrationObserver: NSObjectProtocol?
    private init() {
        registrationObserver = NotificationCenter.default.addObserver(forName: EditorToolRegistry.didRegister, object: nil, queue: .main) { [weak self] _ in
            self?.mergeRegisteredTools()
        }
        loadShortcuts()
    }

    // MARK: - Default Shortcuts

    /// 기본 단축키 설정
    private static var defaultBindings: [ShortcutBinding] {
        [
            // 파일
            ShortcutBinding(action: .newFile, key: "n", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .newFolder, key: "n", modifiers: [.command, .shift], isEnabled: true),
            ShortcutBinding(action: .openFile, key: "o", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .save, key: "s", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .saveAs, key: "s", modifiers: [.command, .shift], isEnabled: true),
            ShortcutBinding(action: .closeTab, key: "w", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .closeAllTabs, key: "w", modifiers: [.command, .option], isEnabled: true),

            ShortcutBinding(action: .copyPath, key: "c", modifiers: [.command, .option, .shift], isEnabled: true),
            ShortcutBinding(action: .copyRelativePath, key: "c", modifiers: [.command, .option], isEnabled: true),
            ShortcutBinding(action: .renameItem, key: "return", modifiers: [], isEnabled: true),

            // 편집
            ShortcutBinding(action: .undo, key: "z", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .redo, key: "z", modifiers: [.command, .shift], isEnabled: true),
            ShortcutBinding(action: .cut, key: "x", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .copy, key: "c", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .paste, key: "v", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .selectAll, key: "a", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .find, key: "f", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .findAndReplace, key: "f", modifiers: [.command, .option], isEnabled: true),
            ShortcutBinding(action: .moveLineUp, key: "up", modifiers: .option, isEnabled: true),
            ShortcutBinding(action: .moveLineDown, key: "down", modifiers: .option, isEnabled: true),
            ShortcutBinding(action: .duplicateLineUp, key: "up", modifiers: [.option, .shift], isEnabled: true),
            ShortcutBinding(action: .duplicateLineDown, key: "down", modifiers: [.option, .shift], isEnabled: true),
            ShortcutBinding(action: .deleteWordBackward, key: "backspace", modifiers: .option, isEnabled: true),
            ShortcutBinding(action: .deleteToLineStart, key: "backspace", modifiers: .command, isEnabled: true),

            // 보기
            ShortcutBinding(action: .toggleSidebar, key: "b", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .toggleAIPanel, key: "j", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .zoomIn, key: "=", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .zoomOut, key: "-", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .resetZoom, key: "0", modifiers: .command, isEnabled: true),

            // 탭 네비게이션
            ShortcutBinding(action: .nextTab, key: "tab", modifiers: .control, isEnabled: true),
            ShortcutBinding(action: .previousTab, key: "tab", modifiers: [.control, .shift], isEnabled: true),
            ShortcutBinding(action: .goToTab1, key: "1", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab2, key: "2", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab3, key: "3", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab4, key: "4", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab5, key: "5", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab6, key: "6", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab7, key: "7", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab8, key: "8", modifiers: .command, isEnabled: true),
            ShortcutBinding(action: .goToTab9, key: "9", modifiers: .command, isEnabled: true),


            // 프로젝트
            ShortcutBinding(action: .openProject, key: "o", modifiers: [.command, .shift], isEnabled: true),
            ShortcutBinding(action: .newProject, key: "n", modifiers: [.command, .option], isEnabled: true),
            ShortcutBinding(action: .refreshProject, key: "r", modifiers: .command, isEnabled: true),
        ] + EditorToolRegistry.tools.map { tool in
            var modifiers: ModifierKeys = []
            if tool.modifiers.contains(.command) { modifiers.insert(.command) }
            if tool.modifiers.contains(.option) { modifiers.insert(.option) }
            if tool.modifiers.contains(.shift) { modifiers.insert(.shift) }
            if tool.modifiers.contains(.control) { modifiers.insert(.control) }
            return ShortcutBinding(action: ShortcutAction(rawValue: tool.id), key: tool.key, modifiers: modifiers, isEnabled: true)
        }
    }

    private func mergeRegisteredTools() {
        var known = Set(bindings.map(\.action))
        for var binding in Self.defaultBindings where known.insert(binding.action).inserted {
            // Newly introduced defaults must not steal an existing custom binding.
            if !binding.key.isEmpty, findConflict(key: binding.key, modifiers: binding.modifiers, excluding: binding.action) != nil {
                binding.key = ""
                binding.modifiers = []
            }
            bindings.append(binding)
        }
    }

    // MARK: - Load & Save

    /// 단축키 파일 로드
    func loadShortcuts() {
        if FileManager.default.fileExists(atPath: shortcutsFileURL.path) {
            do {
                let data = try Data(contentsOf: shortcutsFileURL)
                let decoder = JSONDecoder()
                bindings = try decoder.decode([ShortcutBinding].self, from: data)

                // Migrate the previous default pair together, without overwriting custom keys.
                if let absolute = bindings.firstIndex(where: { $0.action == .copyPath }),
                   let relative = bindings.firstIndex(where: { $0.action == .copyRelativePath }),
                   bindings[absolute].key == "c", bindings[absolute].modifiers == [.command, .option],
                   bindings[relative].key == "c", bindings[relative].modifiers == [.command, .option, .shift] {
                    bindings[absolute].modifiers = [.command, .option, .shift]
                    bindings[relative].modifiers = [.command, .option]
                }
                for index in bindings.indices where bindings[index].action == .copyPath || bindings[index].action == .copyRelativePath {
                    let old: ModifierKeys = bindings[index].action == .copyPath ? [.control, .option] : [.control, .option, .shift]
                    let updated: ModifierKeys = bindings[index].action == .copyPath ? [.command, .option, .shift] : [.command, .option]
                    if bindings[index].key == "c", bindings[index].modifiers == old,
                       findConflict(key: "c", modifiers: updated, excluding: bindings[index].action) == nil {
                        bindings[index].modifiers = updated
                    }
                }
                mergeRegisteredTools()
            } catch {
                print("Failed to load shortcuts: \(error)")
                bindings = Self.defaultBindings
            }
        } else {
            // 파일이 없으면 기본값 사용
            bindings = Self.defaultBindings
            saveShortcuts()
        }
    }

    /// 단축키 파일 저장
    func saveShortcuts() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(bindings)
            try data.write(to: shortcutsFileURL)
        } catch {
            print("Failed to save shortcuts: \(error)")
        }
    }

    // MARK: - Get & Update

    /// 특정 액션의 단축키 바인딩 가져오기
    func binding(for action: ShortcutAction) -> ShortcutBinding? {
        bindings.first { $0.action == action }
    }

    /// The single presentation path for toolbar help and AppKit context menus.
    func displayShortcut(for actionID: String) -> String? {
        guard let binding = binding(for: ShortcutAction(rawValue: actionID)),
              binding.isEnabled, !binding.key.isEmpty else { return nil }
        return binding.displayString
    }

    func helpText(title: String, actionID: String) -> String {
        guard let shortcut = displayShortcut(for: actionID) else { return title }
        return "\(title) (\(shortcut))"
    }

    func toolHelpText(_ toolID: String) -> String {
        helpText(title: EditorToolRegistry.title(for: toolID), actionID: toolID)
    }

    /// 단축키 바인딩 업데이트
    func updateBinding(_ binding: ShortcutBinding) {
        if let index = bindings.firstIndex(where: { $0.action == binding.action }) {
            bindings[index] = binding
            saveShortcuts()
        }
    }

    /// 단축키 활성화/비활성화 토글
    func toggleEnabled(for action: ShortcutAction) {
        if let index = bindings.firstIndex(where: { $0.action == action }) {
            bindings[index].isEnabled.toggle()
            saveShortcuts()
        }
    }

    /// 특정 액션의 단축키 키 변경
    func setKey(_ key: String, modifiers: ModifierKeys, for action: ShortcutAction) {
        if let index = bindings.firstIndex(where: { $0.action == action }) {
            bindings[index].key = key
            bindings[index].modifiers = modifiers
            saveShortcuts()
        }
    }

    /// 기본값으로 초기화
    func resetToDefaults() {
        bindings = Self.defaultBindings
        saveShortcuts()
    }

    /// 특정 액션만 기본값으로 초기화
    func resetToDefault(for action: ShortcutAction) {
        if let defaultBinding = Self.defaultBindings.first(where: { $0.action == action }),
           let index = bindings.firstIndex(where: { $0.action == action }) {
            bindings[index] = defaultBinding
            saveShortcuts()
        }
    }

    // MARK: - Conflict Detection

    /// 단축키 충돌 확인
    func findConflict(key: String, modifiers: ModifierKeys, excluding action: ShortcutAction) -> ShortcutBinding? {
        guard !key.isEmpty else { return nil }
        return bindings.first { binding in
            binding.action != action &&
            binding.isEnabled &&
            Self.canonicalKey(binding.key) == Self.canonicalKey(key) &&
            binding.modifiers == modifiers
        }
    }

    func action(matching event: NSEvent) -> ShortcutAction? {
        let key: String
        switch event.keyCode {
        case 126: key = "up"
        case 125: key = "down"
        case 123: key = "left"
        case 124: key = "right"
        case 51: key = "backspace"
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 49: key = "space"
        case 53: key = "escape"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageup"
        case 121: key = "pagedown"
        default: key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        var modifiers: ModifierKeys = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return bindings.first { !$0.key.isEmpty && $0.isEnabled && Self.canonicalKey($0.key) == key && $0.modifiers == modifiers }?.action
    }

    /// Use the same named keys/aliases accepted by KeyEquivalent when matching AppKit events.
    private static func canonicalKey(_ key: String) -> String {
        switch key.lowercased() {
        case "enter": return "return"
        case "delete": return "backspace"
        case "esc": return "escape"
        case " ": return "space"
        default: return key.lowercased()
        }
    }

    // MARK: - Category Helpers

    /// 카테고리별 바인딩 가져오기
    func bindings(for category: ShortcutCategory) -> [ShortcutBinding] {
        bindings.filter { $0.action.category == category }
    }
}
