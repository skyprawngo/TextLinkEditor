//
//  AppCommands.swift
//  TextlinkEditor
//
//  앱 전역 커맨드 관리 - 단축키 액션 전달용
//

import SwiftUI
import Combine

// MARK: - App Commands

/// 앱 전역 커맨드 관리자
/// 메뉴바 단축키 액션을 뷰로 전달하는 역할
final class AppCommands: ObservableObject {
    static let shared = AppCommands()

    // MARK: - File Commands
    @Published var newFileRequested = false
    @Published var newFolderRequested = false
    @Published var openFileRequested = false
    @Published var saveRequested = false
    @Published var saveAsRequested = false
    @Published var closeTabRequested = false
    @Published var closeAllTabsRequested = false

    // MARK: - Edit Commands
    @Published var searchResultLine: Int?
    @Published var searchInDocument: String?
    @Published var findRequested = false
    @Published var findAndReplaceRequested = false

    // MARK: - View Commands
    @Published var toggleSidebarRequested = false
    @Published var toggleAIPanelRequested = false
    @Published var zoomInRequested = false
    @Published var zoomOutRequested = false
    @Published var resetZoomRequested = false

    // MARK: - Tab Commands
    @Published var nextTabRequested = false
    @Published var previousTabRequested = false
    @Published var goToTabRequested: Int? = nil

    // MARK: - Project Commands
    @Published var openProjectRequested = false
    @Published var newProjectRequested = false
    @Published var refreshProjectRequested = false

    private init() {}

    // MARK: - Reset Methods

    /// 파일 커맨드 리셋
    func resetFileCommands() {
        newFileRequested = false
        newFolderRequested = false
        openFileRequested = false
        saveRequested = false
        saveAsRequested = false
        closeTabRequested = false
        closeAllTabsRequested = false
    }

    /// 편집 커맨드 리셋
    func resetEditCommands() {
        findRequested = false
        findAndReplaceRequested = false
    }

    /// 보기 커맨드 리셋
    func resetViewCommands() {
        toggleSidebarRequested = false
        toggleAIPanelRequested = false
        zoomInRequested = false
        zoomOutRequested = false
        resetZoomRequested = false
    }

    /// 탭 커맨드 리셋
    func resetTabCommands() {
        nextTabRequested = false
        previousTabRequested = false
        goToTabRequested = nil
    }

    /// 프로젝트 커맨드 리셋
    func resetProjectCommands() {
        openProjectRequested = false
        newProjectRequested = false
        refreshProjectRequested = false
    }
}

// MARK: - TextlinkEditor Commands

/// 앱 메뉴바 커맨드 정의
struct TextlinkEditorCommands: Commands {
    @ObservedObject var appCommands: AppCommands

    var body: some Commands {
        CommandMenu(L10n.get("toolbar.format")) {
            ForEach(EditorToolRegistry.tools) { tool in
                Button(L10n.get(tool.titleKey)) {
                    EditorToolRegistry.requestExecution(tool.id)
                }
                .configuredShortcut(ShortcutAction(rawValue: tool.id))
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.get("shortcut.edit.undo")) { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.configuredShortcut(.undo)
            Button(L10n.get("shortcut.edit.redo")) { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.configuredShortcut(.redo)
        }
        CommandGroup(replacing: .pasteboard) {
            Button(L10n.get("shortcut.edit.cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.configuredShortcut(.cut)
            Button(L10n.get("shortcut.edit.copy")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.configuredShortcut(.copy)
            Button(L10n.get("shortcut.edit.paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.configuredShortcut(.paste)
            Button(L10n.get("shortcut.edit.selectAll")) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.configuredShortcut(.selectAll)
        }
        // 파일 메뉴
        CommandGroup(replacing: .newItem) {
            Button(L10n.get("shortcut.project.new")) { appCommands.newProjectRequested = true }
                .configuredShortcut(.newProject)
            Button(L10n.get("shortcut.project.refresh")) { appCommands.refreshProjectRequested = true }
                .configuredShortcut(.refreshProject)
            Divider()
            Button(L10n.get("shortcut.file.new")) {
                appCommands.newFileRequested = true
            }
            .configuredShortcut(.newFile)

            Button(L10n.get("shortcut.file.newFolder")) {
                appCommands.newFolderRequested = true
            }
            .configuredShortcut(.newFolder)

            Divider()

            Button(L10n.get("shortcut.file.open")) {
                appCommands.openFileRequested = true
            }
            .configuredShortcut(.openFile)

            Button(L10n.get("shortcut.project.open")) {
                appCommands.openProjectRequested = true
            }
            .configuredShortcut(.openProject)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.get("shortcut.file.save")) {
                appCommands.saveRequested = true
            }
            .configuredShortcut(.save)

            Button(L10n.get("shortcut.file.saveAs")) {
                appCommands.saveAsRequested = true
            }
            .configuredShortcut(.saveAs)
        }

        // 편집 메뉴 - 찾기
        CommandGroup(after: .pasteboard) {
            Divider()

            Button(L10n.get("shortcut.edit.find")) {
                appCommands.findRequested = true
            }
            .configuredShortcut(.find)

            Button(L10n.get("shortcut.edit.findAndReplace")) {
                appCommands.findAndReplaceRequested = true
            }
            .configuredShortcut(.findAndReplace)
        }

        // 보기 메뉴
        CommandGroup(replacing: .sidebar) {
            Button(L10n.get("shortcut.view.toggleSidebar")) {
                appCommands.toggleSidebarRequested = true
            }
            .configuredShortcut(.toggleSidebar)

            Button(L10n.get("shortcut.view.toggleAIPanel")) {
                appCommands.toggleAIPanelRequested = true
            }
            .configuredShortcut(.toggleAIPanel)

            Divider()

            Button(L10n.get("shortcut.view.zoomIn")) {
                appCommands.zoomInRequested = true
            }
            .configuredShortcut(.zoomIn)

            Button(L10n.get("shortcut.view.zoomOut")) {
                appCommands.zoomOutRequested = true
            }
            .configuredShortcut(.zoomOut)

            Button(L10n.get("shortcut.view.resetZoom")) {
                appCommands.resetZoomRequested = true
            }
            .configuredShortcut(.resetZoom)
        }

        // 창 메뉴 - 탭 네비게이션
        CommandGroup(after: .windowArrangement) {
            Divider()

            Button(L10n.get("shortcut.tab.next")) {
                appCommands.nextTabRequested = true
            }
            .configuredShortcut(.nextTab)

            Button(L10n.get("shortcut.tab.previous")) {
                appCommands.previousTabRequested = true
            }
            .configuredShortcut(.previousTab)

            Divider()

            Button(L10n.get("shortcut.file.closeTab")) {
                appCommands.closeTabRequested = true
            }
            .configuredShortcut(.closeTab)

            Button(L10n.get("shortcut.file.closeAllTabs")) {
                appCommands.closeAllTabsRequested = true
            }
            .configuredShortcut(.closeAllTabs)

            Divider()

            // 탭 1-9 이동
            ForEach(1...9, id: \.self) { index in
                Button(L10n.get("shortcut.tab.goTo\(index)")) {
                    appCommands.goToTabRequested = index
                }

                .configuredShortcut(ShortcutAction(rawValue: "tab.goTo\(index)"))
            }
        }

        // 도움말 메뉴
        CommandGroup(replacing: .help) {
            Button(L10n.get("terms.title")) {
                TermsWindowController.shared.openTermsWindow()
            }
        }
    }
}

private struct ConfiguredShortcut: ViewModifier {
    let action: ShortcutAction
    @State private var manager = KeyboardShortcutManager.shared
    func body(content: Content) -> some View {
        content.keyboardShortcut(manager.binding(for: action)?.keyboardShortcut)
    }
}

extension View {
    func configuredShortcut(_ action: ShortcutAction) -> some View {
        modifier(ConfiguredShortcut(action: action))
    }
}
