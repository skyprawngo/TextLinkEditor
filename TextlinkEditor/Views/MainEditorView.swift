//
//  MainEditorView.swift
//  TextlinkEditor
//
//  메인 에디터 화면
//  계층 구조:
//  - MainEditorView (HStack)
//    ├── NavigationSplitView
//    │   ├── ProjectExplorerView (sidebar)
//    │   └── EditorContainerView (detail)
//    └── AIAssistantView (우측 패널)
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Toolbar Search Field

final class ToolbarNativeSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// 툴바용 NSSearchField 래퍼
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var onSearch: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = ToolbarNativeSearchField()
        searchField.placeholderString = prompt
        searchField.delegate = context.coordinator
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else { return }
            searchField.window?.makeFirstResponder(searchField)
        }
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.onSearch = onSearch
        context.coordinator.onCancel = onCancel
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSearch: onSearch)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        var onCancel: () -> Void = {}
        var onSearch: () -> Void
        init(text: Binding<String>, onSearch: @escaping () -> Void) {
            _text = text
            self.onSearch = onSearch
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onCancel(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { onSearch(); return true }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // Let AppKit finish transferring the responder before removing the field.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let field, field.currentEditor() == nil,
                      field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self?.onCancel()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let searchField = obj.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}

private struct VersionPresentation: Identifiable {
    let id = UUID()
    let project: URL
    let document: URL
    let draft: String?
}

private struct ProjectSearchPresentation: Identifiable {
    let id = UUID()
    let projectURL: URL?
}

struct MainEditorView: View {
    @Bindable var projectManager: ProjectManager
    @EnvironmentObject var appCommands: AppCommands
    @Environment(\.openWindow) private var openWindow

    private var fileSystemManager: FileSystemManager { FileSystemManager.shared }
    @State private var tabManager = EditorTabManager.shared
    @State private var assistant = AIAssistantViewModel.shared
    @State private var git = ProjectGitModel()

    // AI 패널 크기
    @State private var panelDragStartWidth: CGFloat?
    @State private var aiPanelWidth = UserSettings.shared.aiAssistantPanelWidth
    @State private var projectSearchPresentation: ProjectSearchPresentation?
    @State private var showingNewProject = false
    @State private var contextProject: ProjectSearchPresentation?
    @State private var writingProject: ProjectSearchPresentation?
    @State private var versionsDocument: VersionPresentation?
    @AppStorage("writing.focusMode") private var focusMode = false
    @State private var focusPreviousSidebar: NavigationSplitViewVisibility = .all
    @State private var focusPreviousAI = true
    @State private var newProjectName = ""
    @State private var newProjectDirectory: URL?

    // UI 상태
    @State private var isAIPanelVisible: Bool = true
    @State private var isAIDetailView: Bool = false  // AI 패널 상세 뷰 모드
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText: String = ""
    @State private var isSearchExpanded = false
    @State private var windowWidth: CGFloat = 1400
    @State private var editorWidth: CGFloat = 800
    @State private var sidebarWidth: CGFloat = 250

    private var resolvedAIPanelWidth: CGFloat {
        min(aiPanelWidth, max(280, windowWidth - (columnVisibility == .detailOnly ? 0 : sidebarWidth) - 360))
    }

    var body: some View {
        HStack(spacing: 0) {
            // 메인 콘텐츠 (NavigationSplitView)
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // 사이드바 (ProjectExplorerView)
                ProjectExplorerView(git: git, collaboration: assistant.collaboration)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
            } detail: {
                // 에디터 컨테이너
                EditorContainerView(projectManager: projectManager)
                    .environmentObject(appCommands)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorWidth = $0 }
            }
            .navigationSplitViewStyle(.balanced)

            // AI 패널 (우측)
            HStack(spacing: 0) {
                Rectangle().fill(AppColors.separator).frame(width: 1)
                    .padding(.horizontal, 3)
                    .background(PanelResizeCursorRegion())
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                        if panelDragStartWidth == nil { panelDragStartWidth = resolvedAIPanelWidth }
                        let maximum = min(600, max(280, windowWidth - (columnVisibility == .detailOnly ? 0 : sidebarWidth) - 360))
                        aiPanelWidth = min(maximum, max(280, (panelDragStartWidth ?? resolvedAIPanelWidth) - value.translation.width))
                    }.onEnded { _ in
                        UserSettings.shared.aiAssistantPanelWidth = aiPanelWidth
                        panelDragStartWidth = nil
                    })
                // Hiding a panel must not recreate its account/chat state or cancel its request.
                ZStack {
                    AIAssistantView(
                    projectFolderURL: projectManager.currentProject?.path,
                    isInDetailView: $isAIDetailView
                    )
                    .opacity(assistant.collaboration.showingPanel ? 0 : 1)
                    .accessibilityHidden(assistant.collaboration.showingPanel)
                    .allowsHitTesting(!assistant.collaboration.showingPanel)
                    if assistant.collaboration.showingPanel {
                        CollaborationView(coordinator: assistant.collaboration, git: git)
                    }
                }
                .frame(width: resolvedAIPanelWidth)
            }
            .frame(width: resolvedAIPanelWidth + 7)
            // Keep the panel alive, but resize the editor once rather than on every animation frame.
            .frame(width: isAIPanelVisible ? resolvedAIPanelWidth + 7 : 0, alignment: .trailing)
            .clipped()
            .accessibilityHidden(!isAIPanelVisible)
            .allowsHitTesting(isAIPanelVisible)
        }
        .background(ThemeAwareBackground(material: .sidebar, blendingMode: .behindWindow, tintOpacity: 0.22)
            .ignoresSafeArea(edges: .top))
        .frame(minWidth: 1000, minHeight: 500)

        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    NavigationButtonsView(onBack: goBack, onForward: goForward,
                        canGoBack: tabManager.canGoBack, canGoForward: tabManager.canGoForward)
                    Group {
                        if isSearchExpanded {
                            ToolbarSearchField(text: $searchText,
                                prompt: L10n.get("toolbar.searchPlaceholder"),
                                onSearch: { projectSearchPresentation = ProjectSearchPresentation(projectURL: projectManager.currentProject?.path) },
                                onCancel: { isSearchExpanded = false })
                                .frame(width: min(200, max(140, editorWidth * 0.3)), height: 30)
                                .glassEffect(.regular, in: .capsule)
                        } else {
                            Button { isSearchExpanded = true } label: {
                                Image(systemName: "magnifyingglass").frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .help(L10n.get("search.project"))
                            .accessibilityLabel(L10n.get("search.project"))
                        }
                    }
                    TabBarView()
                        .frame(minWidth: 100, maxWidth: .infinity)
                }
                .animation(.smooth(duration: 0.22), value: isSearchExpanded)
                // Reserve window controls and trailing actions independently of sidebar visibility.
                // Expanding this item when the sidebar closes pushes actions into toolbar overflow.
                .frame(width: max(300, windowWidth - 570))
            }
            .sharedBackgroundVisibility(.hidden)

            // A toolbar Spacer consumes the remaining window width before the action groups.
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button(L10n.get("writing.workspace")) {
                        writingProject = ProjectSearchPresentation(projectURL: projectManager.currentProject?.path)
                    }
                    Button(L10n.get("versions.title")) {
                        tabManager.flushEditor()
                        if let project = projectManager.currentProject?.path, let tab = tabManager.selectedTab {
                            versionsDocument = VersionPresentation(project: project, document: tab.url, draft: tabManager.getCachedContent(for: tab.url))
                        }
                    }.disabled(tabManager.selectedTab == nil)
                    Divider()
                    Toggle(L10n.get("writing.focus"), isOn: $focusMode)
                } label: { Label(L10n.get("writing.workspace"), systemImage: "book.closed") }
                .help(L10n.get("writing.workspace"))
            }
            ToolbarSpacer(.fixed, placement: .automatic)
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    if isAIPanelVisible && assistant.collaboration.showingPanel { isAIPanelVisible = false }
                    else { assistant.collaboration.showingPanel = true; isAIPanelVisible = true }
                } label: {
                    Label(L10n.get("git.openCollaboration"), systemImage: "person.2.wave.2")
                }
                .help(L10n.get("git.openCollaboration"))
                .accessibilityLabel(L10n.get("git.openCollaboration"))
                Button {
                    if assistant.collaboration.showingPanel { assistant.collaboration.showingPanel = false; isAIPanelVisible = true }
                    else { isAIPanelVisible.toggle() }
                } label: {
                    Label(L10n.ai.togglePanel, systemImage: "bubble.left.and.bubble.right")
                }
                .help(L10n.ai.togglePanel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("editorInlineAI"))) { notification in
            guard let native = notification.object as? NativeManuscriptTextView,
                  native.window != nil, let project = projectManager.currentProject?.path else { return }
            if native.inlinePanel != nil { return }
            let source = native.string as NSString
            let selected = native.selectedRange()
            let selectedText = source.substring(with: selected)
            let range = selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? NSRange(location: selected.location, length: 0) : selected
            guard let tab = tabManager.selectedTab else { return }
            let root = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let path = tab.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root) else { return }
            let revision = ManuscriptRevision(id: UUID(), relativePath: String(path.dropFirst(root.count)), original: native.string,
                selectionLocation: range.location, selectionLength: range.length)
            let panel = NSHostingView(rootView: InlineAIChatView(projectURL: project, revision: revision, onClose: { [weak native] in
                guard let native, native.inlinePanel != nil else { return }
                native.execute(EditorCommand(.tool("ai.inline")))
            }))
            panel.sizingOptions = []
            native.installInlinePanel(panel)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aiAttachSelection"))) { notification in
            guard let text = notification.object as? String, let project = projectManager.currentProject?.path,
                  let tab = tabManager.selectedTab else { return }
            do {
                try AIContextSelection.shared.captureSelection(text, sourceURL: tab.url, projectURL: project)
                contextProject = ProjectSearchPresentation(projectURL: project)
                assistant.collaboration.showingPanel = false
                isAIPanelVisible = true
            } catch { fileSystemManager.operationError = error.localizedDescription }
        }
        .sheet(item: $contextProject) { item in
            if let url = item.projectURL {
                AIContextPickerView(projectURL: url, onReviewRequested: assistant.prepareDraftAction)
            }
        }
        .sheet(item: $writingProject) { item in
            if let url = item.projectURL { WritingWorkspaceView(projectURL: url) }
        }
        .sheet(item: $versionsDocument) { item in
            ManuscriptVersionsView(projectURL: item.project, documentURL: item.document, draftContent: item.draft)
        }
        .onChange(of: focusMode) { _, enabled in
            if enabled {
                focusPreviousSidebar = columnVisibility
                focusPreviousAI = isAIPanelVisible
                columnVisibility = .detailOnly
                isAIPanelVisible = false
            } else {
                columnVisibility = focusPreviousSidebar
                isAIPanelVisible = focusPreviousAI
            }
        }
        .sheet(item: $projectSearchPresentation) { presentation in
            ProjectSearchView(projectURL: presentation.projectURL, query: $searchText)
        }
        .alert(L10n.get("storage.operationFailed"), isPresented: Binding(
            get: { fileSystemManager.operationError != nil },
            set: { if !$0 { fileSystemManager.operationError = nil } }
        )) {
            Button(L10n.common.confirm) { fileSystemManager.operationError = nil }
        } message: { Text(fileSystemManager.operationError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aiDraftAction"))) { notification in
            assistant.collaboration.showingPanel = false
            if !isAIPanelVisible {
                isAIPanelVisible = true
                DispatchQueue.main.async { NotificationCenter.default.post(notification) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("collaborationCommentRequested"))) { _ in
            assistant.setProject(projectManager.currentProject?.path)
            assistant.collaboration.captureComment()
            isAIPanelVisible = true
        }
        .onReceive(appCommands.$newProjectRequested) { requested in
            if requested {
                appCommands.newProjectRequested = false
                newProjectDirectory = projectManager.defaultSaveDirectory
                showingNewProject = true
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(projectName: $newProjectName, selectedDirectory: $newProjectDirectory, projectManager: projectManager) { options in
                guard let directory = newProjectDirectory,
                      projectManager.createProject(name: newProjectName, at: directory, options: options) != nil else { return }
                showingNewProject = false
                newProjectName = ""
                initializeFileSystem()
            } onCancel: { showingNewProject = false }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            initializeFileSystem()
            if focusMode { columnVisibility = .detailOnly; isAIPanelVisible = false }
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            git.setProject(nil)
            assistant.setProject(nil)
            fileSystemManager.closeProject()
        }
        .onChange(of: projectManager.currentProject?.path) { _, path in
            git.setProject(path)
            assistant.setProject(path)
        }
        .onChange(of: assistant.collaboration.showingPanel) { _, showing in
            if showing { isAIPanelVisible = true }
        }
        .appCommandHandler(
            appCommands: appCommands,
            tabManager: tabManager,
            fileSystemManager: fileSystemManager,
            projectManager: projectManager,
            isAIPanelVisible: $isAIPanelVisible,
            columnVisibility: $columnVisibility,
            onInitializeFileSystem: initializeFileSystem
        )
    }

    // MARK: - File System

    private func initializeFileSystem() {
        guard let projectPath = projectManager.currentProject?.path else { return }
        assistant.setProject(projectPath)
        git.setProject(projectPath)
        fileSystemManager.initializeProject(at: projectPath)
    }

    // MARK: - Navigation

    private func goBack() {
        tabManager.goBack()
    }

    private func goForward() {
        tabManager.goForward()
    }
}

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

#Preview {
    MainEditorView(projectManager: ProjectManager.shared)
        .environmentObject(AppCommands.shared)
}
