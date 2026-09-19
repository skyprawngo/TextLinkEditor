import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Command Handler Modifier

/// 앱 커맨드 핸들러를 통합한 ViewModifier
struct AppCommandHandlerModifier: ViewModifier {
    let appCommands: AppCommands
    let tabManager: EditorTabManager
    let fileSystemManager: FileSystemManager
    let projectManager: ProjectManager
    @Binding var isAIPanelVisible: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let onInitializeFileSystem: () -> Void

    func body(content: Content) -> some View {
        content
            // 탭 관련 커맨드
            .onReceive(appCommands.$closeTabRequested) { requested in
                if requested {
                    tabManager.closeCurrentTab()
                    appCommands.closeTabRequested = false
                }
            }
            .onReceive(appCommands.$closeAllTabsRequested) { requested in
                if requested {
                    tabManager.closeAllTabs()
                    appCommands.closeAllTabsRequested = false
                }
            }
            .onReceive(appCommands.$nextTabRequested) { requested in
                if requested {
                    tabManager.selectNextTab()
                    appCommands.nextTabRequested = false
                }
            }
            .onReceive(appCommands.$previousTabRequested) { requested in
                if requested {
                    tabManager.selectPreviousTab()
                    appCommands.previousTabRequested = false
                }
            }
            .onReceive(appCommands.$goToTabRequested) { tabIndex in
                if let index = tabIndex {
                    tabManager.selectTab(at: index - 1)
                    appCommands.goToTabRequested = nil
                }
            }
            // UI 토글 커맨드
            .onReceive(appCommands.$toggleSidebarRequested) { requested in
                if requested {
                    columnVisibility = columnVisibility == .all ? .detailOnly : .all
                    appCommands.toggleSidebarRequested = false
                }
            }
            .onReceive(appCommands.$toggleAIPanelRequested) { requested in
                if requested {
                    isAIPanelVisible.toggle()
                    appCommands.toggleAIPanelRequested = false
                }
            }
            // 파일/폴더 커맨드
            .onReceive(appCommands.$newFileRequested) { requested in
                if requested {
                    if let rootItem = fileSystemManager.targetDirectoryForNewFile {
                        fileSystemManager.showNewFileDialog(in: rootItem) { _ in }
                    }
                    appCommands.newFileRequested = false
                }
            }
            .onReceive(appCommands.$newFolderRequested) { requested in
                if requested {
                    if let rootItem = fileSystemManager.projectRoot {
                        fileSystemManager.showNewFolderDialog(in: rootItem) { _ in }
                    }
                    appCommands.newFolderRequested = false
                }
            }
            .onReceive(appCommands.$refreshProjectRequested) { requested in
                if requested {
                    fileSystemManager.refreshProject()
                    appCommands.refreshProjectRequested = false
                }
            }
            .onReceive(appCommands.$openFileRequested) { requested in
                if requested {
                    handleOpenFile()
                    appCommands.openFileRequested = false
                }
            }
            .onReceive(appCommands.$openProjectRequested) { requested in
                if requested {
                    handleOpenProject()
                    appCommands.openProjectRequested = false
                }
            }
    }

    private func handleOpenFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.get("shortcut.file.open")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.text, .plainText, .utf8PlainText]

        if let projectPath = projectManager.currentProject?.path {
            panel.directoryURL = projectPath
        }

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let fileItem = FileSystemItem(url: url, isDirectory: false)
            tabManager.openFile(fileItem)
        }
    }

    private func handleOpenProject() {
        guard let url = projectManager.showOpenPanel() else { return }

        // 새 프로젝트 열기 (openProjectFromFile 내부에서 세션 복원됨)
        if projectManager.openProjectFromFile(at: url) != nil {
            onInitializeFileSystem()
        }
    }
}

extension View {
    func appCommandHandler(
        appCommands: AppCommands,
        tabManager: EditorTabManager,
        fileSystemManager: FileSystemManager,
        projectManager: ProjectManager,
        isAIPanelVisible: Binding<Bool>,
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        onInitializeFileSystem: @escaping () -> Void
    ) -> some View {
        modifier(AppCommandHandlerModifier(
            appCommands: appCommands,
            tabManager: tabManager,
            fileSystemManager: fileSystemManager,
            projectManager: projectManager,
            isAIPanelVisible: isAIPanelVisible,
            columnVisibility: columnVisibility,
            onInitializeFileSystem: onInitializeFileSystem
        ))
    }
}
