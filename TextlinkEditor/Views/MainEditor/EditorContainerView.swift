//
//  EditorContainerView.swift
//  TextlinkEditor
//
//  에디터 컨테이너 뷰 - TabBar + Toolbar + TextEditor + StatusBar
//  MainEditorView의 하위 컴포넌트
//

import SwiftUI

// MARK: - Editor Container View

/// 에디터 컨테이너 (탭바 + 툴바 + 텍스트 에디터 + 상태바)
struct EditorContainerView: View {
    @EnvironmentObject var appCommands: AppCommands
    let projectManager: ProjectManager

    @State private var tabManager = EditorTabManager.shared

    // 에디터 상태
    @State private var text: String = ""
    @AppStorage("writing.focusMode") private var focusMode = false
    @State private var statisticsTask: Task<Void, Never>?
    @State private var statisticsRequest = UUID()
    @State private var wordCount = 0
    @State private var characterCount = 0
    @State private var lineCount = 1
    @State private var presentedTool: String?
    @State private var isMarkdownPreview = false
    @State private var fontSize: CGFloat = UserSettings.shared.editorFontSize
    @State private var fontName: String = UserSettings.shared.editorFontName
    @State private var lineSpacingOption: LineSpacingOption = .normal
    @State private var letterSpacing: CGFloat = UserSettings.shared.editorLetterSpacing
    @State private var appearanceError: String?
    @State private var cursorLine: Int = 1
    @State private var cursorColumn: Int = 0
    @State private var editCommand: EditorCommand?
    @State private var currentDocumentID: UUID?
    @State private var contentRevision = UUID()
    @State private var loadError: String?
    @State private var documentLoadTask: Task<Void, Never>?
    @State private var documentLoadID = UUID()
    @State private var preparedContent: PreparedManuscript?
    @State private var showingFind = false
    @State private var showingReplace = false
    @State private var findText = ""
    @State private var replacementText = ""
    @State private var selectedLineRange: ClosedRange<Int>?
    @State private var currentFileURL: URL?
    @State private var previousFileURL: URL?  // 탭 전환 시 이전 파일 URL 추적
    @State private var isLoading: Bool = false
    @State private var initialCursorPosition: (line: Int, column: Int)? = nil
    @State private var externallyModifiedLines: Set<Int> = []  // AI가 수정한 줄 번호들

    // 자동 저장 타이머
    @State private var autoSaveTimer: Timer?
    @State private var autoSaveOption: AutoSaveOption = UserSettings.shared.autoSaveOption

    // 외부 파일 변경 감시

    private var currentFileExists: Bool {
        tabManager.selectedTab?.fileExists ?? true
    }

    var body: some View {
        commandContent
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("aiWorkspaceFilesDidChange"))) { notification in
            guard let project = notification.object as? URL,
                  project.standardizedFileURL == projectManager.currentProject?.path?.standardizedFileURL else { return }
            tabManager.refreshExternalDocuments()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorDiskContentDidChange)) { notification in
            guard let url = notification.object as? URL, url == currentFileURL,
                  !isLoading, let state = tabManager.getEditState(for: url) else { return }
            let previous = text
            preparedContent = nil
            loadError = nil
            initialCursorPosition = state.cursorPosition
            contentRevision = UUID()
            text = state.content
            externallyModifiedLines = DocumentFileStore.changedLines(from: previous, to: state.content)
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorDiskStateDidChange)) { _ in
            FileSystemManager.shared.refreshProject()
        }
    }

    private var editorWithState: some View {
        VStack(spacing: 0) {
            if tabManager.isEmpty {
                emptyStateView
            } else {
                // 툴바
                if !focusMode {
                EditorToolbarView(
                    fontSize: appearanceBinding(fontSize, change: EditorAppearanceChange.fontSize),
                    lineSpacingOption: appearanceBinding(lineSpacingOption, change: { .lineSpacing($0.rawValue) }),
                    letterSpacing: appearanceBinding(letterSpacing, change: EditorAppearanceChange.letterSpacing),
                    fontName: appearanceBinding(fontName, change: EditorAppearanceChange.fontName),
                    isMarkdownPreview: isMarkdownPreview,
                    onToolAction: { editCommand = EditorCommand(.tool($0)) },
                    presentedTool: $presentedTool
                )
                .contextMenu {
                    Button(L10n.get("editor.appearance.reset")) {
                        guard let url = tabManager.selectedTab?.url else { return }
                        do { try EditorAppearanceStore.shared.reset(for: url) }
                        catch { appearanceError = error.localizedDescription }
                    }
                }

                }

                if showingFind {
                    HStack {
                        TextField(L10n.get("search.find"), text: $findText)
                            .onSubmit { editCommand = EditorCommand(.find(findText, forward: true)) }
                        Button(L10n.get("search.previous")) { editCommand = EditorCommand(.find(findText, forward: false)) }
                        Button(L10n.get("search.next")) { editCommand = EditorCommand(.find(findText, forward: true)) }
                        if showingReplace {
                            TextField(L10n.get("search.replacement"), text: $replacementText)
                            Button(L10n.get("search.replace")) { editCommand = EditorCommand(.replace(findText, replacement: replacementText, all: false)) }
                            Button(L10n.get("search.replaceAll")) { editCommand = EditorCommand(.replace(findText, replacement: replacementText, all: true)) }
                        }
                        Button(L10n.get("common.close")) { showingFind = false }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                }
                if let message = loadError ?? currentFileURL.flatMap({ tabManager.saveErrors[$0] }) ?? tabManager.recoveryError {
                    HStack {
                        Text(message).foregroundStyle(AppColors.errorIndicator)
                        Spacer()
                        Button(L10n.get("shortcut.file.saveAs")) { tabManager.saveAs() }
                        if loadError != nil {
                            Button(L10n.get("storage.retry")) {
                                let url = currentFileURL
                                currentFileURL = nil
                                loadFileContent(from: url)
                            }
                        }
                    }.padding(8)
                }

                // Native AppKit manuscript editor
                TextlinkEditorRepresentable(
                    text: $text,
                    cursorLine: $cursorLine,
                    cursorColumn: $cursorColumn,
                    selectedLineRange: $selectedLineRange,
                    externallyModifiedLines: $externallyModifiedLines,
                    fontSize: fontSize,
                    fontName: fontName,
                    lineHeightMultiple: lineSpacingOption.lineHeightMultiple,
                    letterSpacing: letterSpacing,
                    isEditable: loadError == nil && !isLoading,
                    initialCursorPosition: initialCursorPosition,
                    onContentWillChange: { ownerURL, finalText, cursorLine, cursorColumn in
                        // 탭 전환 직전: 이전 파일의 최종 텍스트(조합 확정 후)와 커서 위치를 캐시에 저장
                        if let prevURL = ownerURL, tabManager.findTab(with: prevURL) != nil,
                           !(prevURL == currentFileURL && (loadError != nil || isLoading)) {
                            if tabManager.getCachedContent(for: prevURL) != finalText { clearModifiedLinesOnEdit() }
                            tabManager.setCachedContent(finalText, for: prevURL)
                            // 조합 확정 후의 커서 위치 저장 (이미 0-based)
                            tabManager.setCachedCursorPosition(line: cursorLine, column: cursorColumn, for: prevURL)
                        }
                    },
                    documentID: currentDocumentID,
                    documentURL: currentFileURL,
                    editCommand: editCommand,
                    contentRevision: contentRevision,
                    isDocumentActive: { id, url, revision in
                        tabManager.selectedTab?.id == id && tabManager.selectedTab?.url == url && contentRevision == revision
                    },
                    openDocumentIDs: Set(tabManager.tabs.map(\.id)),
                    preparedContent: preparedContent,
                    isSourceVisible: true,
                    rendersMarkdown: isMarkdownPreview,
                    onToolPresentation: { control in
                        if control == "markdownPreview" {
                            tabManager.flushEditor()
                            if let url = currentFileURL, let cached = tabManager.getCachedContent(for: url) { text = cached }
                            isMarkdownPreview.toggle()
                        } else { focusMode = false; presentedTool = control }
                    }
                )
                .background(AppColors.textEditorBackground)
                .clipped()
                .overlay { if isLoading { ProgressView().controlSize(.regular).allowsHitTesting(false) } }

                // 상태바
                EditorStatusBarView(
                    wordCount: wordCount,
                    characterCount: characterCount,
                    lineCount: lineCount,
                    selectedLineRange: selectedLineRange,
                    saveStatus: saveStatus
                )
            }
        }
        .onChange(of: tabManager.selectedTab?.id) { _, _ in
            loadFileContent(from: tabManager.selectedTab?.url)
        }
        .onChange(of: tabManager.selectedTab?.url) { oldURL, newURL in
            tabManager.flushEditor()
            if let oldURL, autoSaveOption == .onTabChange { autoSaveIfModified(for: oldURL) }
            loadFileContent(from: newURL)
        }
        .onChange(of: text) { _, value in
            updateStatistics(value)
        }
        .onChange(of: cursorLine) { _, _ in
            // 커서 위치 변경 시 바로 캐시에 저장 (앱 종료 시 누락 방지)
            // cursorLine은 1-based, 캐시는 0-based로 저장
            guard let url = currentFileURL, !isLoading, loadError == nil, tabManager.findTab(with: url) != nil else { return }
            tabManager.setCachedCursorPosition(line: cursorLine - 1, column: cursorColumn, for: url)
        }
        .onChange(of: cursorColumn) { _, _ in
            // 커서 위치 변경 시 바로 캐시에 저장 (앱 종료 시 누락 방지)
            // cursorLine은 1-based, 캐시는 0-based로 저장
            guard let url = currentFileURL, !isLoading, loadError == nil, tabManager.findTab(with: url) != nil else { return }
            tabManager.setCachedCursorPosition(line: cursorLine - 1, column: cursorColumn, for: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: EditorToolRegistry.executionRequested)) { notification in
            guard let id = notification.object as? String, EditorToolRegistry.definition(id) != nil else { return }
            editCommand = EditorCommand(.tool(id))
        }
        .onReceive(NotificationCenter.default.publisher(for: EditorAppearanceStore.defaultsChanged)) { _ in
            loadAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: EditorAppearanceStore.changed)) { _ in
            if let error = EditorAppearanceStore.shared.error { appearanceError = error.localizedDescription }
            loadAppearance()
        }
        .alert(L10n.get("editor.appearance.error"), isPresented: Binding(
            get: { appearanceError != nil }, set: { if !$0 { appearanceError = nil } })) {
            Button(L10n.common.confirm) { appearanceError = nil }
        } message: { Text(appearanceError ?? "") }
        .onChange(of: projectManager.currentProject?.path) { oldPath, newPath in
            // 프로젝트가 변경되면 해당 프로젝트의 에디터 설정 로드
            if oldPath != newPath {
                loadAppearance()
            }
        }
        .onAppear {
            loadFileContent(from: tabManager.selectedTab?.url)
            loadAppearance()
            setupAutoSaveTimer()
            tabManager.refreshExternalDocuments()
        }
        .onDisappear {
            documentLoadTask?.cancel()
            documentLoadTask = nil
            documentLoadID = UUID()
            statisticsTask?.cancel()
            stopAutoSaveTimer()
        }
        .onChange(of: autoSaveOption) { _, newValue in
            UserSettings.shared.autoSaveOption = newValue
            setupAutoSaveTimer()
        }
    }

    private var commandContent: some View {
        editorWithState
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let updated = UserSettings.shared.autoSaveOption
            if autoSaveOption != updated { autoSaveOption = updated }
        }
        .onReceive(appCommands.$saveAsRequested) { requested in
            if requested { appCommands.saveAsRequested = false; tabManager.saveAs() }
        }
        .onReceive(appCommands.$resetZoomRequested) { requested in
            if requested { appCommands.resetZoomRequested = false; fontSize = UserSettings.shared.editorFontSize }
        }
        .onReceive(appCommands.$findRequested) { requested in
            if requested { appCommands.findRequested = false; showingFind = true; showingReplace = false }
        }
        .onReceive(appCommands.$findAndReplaceRequested) { requested in
            if requested { appCommands.findAndReplaceRequested = false; showingFind = true; showingReplace = true }
        }
        .onReceive(appCommands.$searchInDocument) { query in
            guard let query else { return }
            let resultLine = appCommands.searchResultLine
            appCommands.searchResultLine = nil
            appCommands.searchInDocument = nil
            findText = query
            showingFind = true
            editCommand = EditorCommand(resultLine.map { .locate(line: $0, query: query) } ?? .find(query, forward: true))
        }
        .onReceive(appCommands.$saveRequested) { requested in
            if requested {
                handleSave()
                appCommands.saveRequested = false
            }
        }
        .onReceive(appCommands.$zoomInRequested) { requested in
            if requested {
                increaseFontSize()
                appCommands.zoomInRequested = false
            }
        }
        .onReceive(appCommands.$zoomOutRequested) { requested in
            if requested {
                decreaseFontSize()
                appCommands.zoomOutRequested = false
            }
        }
    }

    // MARK: - Font Size

    /// 폰트 크기 증가 (최대 72pt)
    private func increaseFontSize() {
        let newSize = min(fontSize + 2, 72)
        fontSize = newSize
    }

    /// 폰트 크기 축소 (최소 8pt)
    private func decreaseFontSize() {
        let newSize = max(fontSize - 2, 8)
        fontSize = newSize
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(AppColors.toolbarIcon)

            Text(L10n.get("explorer.selectSection"))
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.textEditorBackground)
    }

    // MARK: - File Loading

    private func loadFileContent(from url: URL?) {
        loadAppearance()
        guard url != currentFileURL || currentDocumentID != tabManager.selectedTab?.id || (isLoading && documentLoadTask == nil) else { return }
        documentLoadTask?.cancel()
        preparedContent = nil
        let request = UUID()
        documentLoadID = request
        currentFileURL = url
        currentDocumentID = tabManager.selectedTab?.id
        contentRevision = UUID()
        initialCursorPosition = nil
        externallyModifiedLines = []
        loadError = nil
        guard let url else { text = ""; isLoading = false; return }
        if let state = tabManager.getEditState(for: url), tabManager.hasLoadedContent(for: url) {
            text = state.content
            initialCursorPosition = state.cursorPosition
            isLoading = false
            tabManager.refreshExternalDocuments()
            return
        }
        isLoading = true
        text = tabManager.getCachedContent(for: url) ?? ""
        let documentID = currentDocumentID
        documentLoadTask = Task { @MainActor in
            do {
                let content = try await tabManager.readDocument(at: url)
                let prepared = content.utf8.count > 250_000
                    ? try await PreparedManuscript.prepare(text: content, fontName: fontName, fontSize: fontSize,
                        lineHeightMultiple: lineSpacingOption.lineHeightMultiple, letterSpacing: letterSpacing, color: AppColors.nsEditorText)
                    : nil
                guard !Task.isCancelled, documentLoadID == request,
                      currentDocumentID == documentID, tabManager.selectedTab?.id == documentID,
                      currentFileURL == url else { return }
                let cursor = tabManager.getCachedCursorPosition(for: url) ?? (0, 0)
                // A late flush/recovery may have created a draft while the read was pending.
                if let draft = tabManager.getEditState(for: url), draft.isModified {
                    text = draft.content
                } else {
                    tabManager.setEditState(TabEditState(content: content, originalContent: content, cursorPosition: cursor), for: url)
                    preparedContent = prepared
                    text = content
                }
                if UserSettings.shared.rememberCursorPosition { initialCursorPosition = cursor }
                contentRevision = UUID()
                isLoading = false
                documentLoadTask = nil
            } catch {
                guard !Task.isCancelled, documentLoadID == request,
                      currentDocumentID == documentID, tabManager.selectedTab?.id == documentID,
                      currentFileURL == url else { return }
                loadError = L10n.get("storage.readFailed") + " " + error.localizedDescription
                isLoading = false
                documentLoadTask = nil
            }
        }
    }

    // MARK: - Save

    private func handleSave() {
        guard loadError == nil, !isLoading else { return }
        tabManager.saveCurrentTab()
    }

    private var saveStatus: String {
        guard let url = currentFileURL else { return "" }
        if tabManager.diskState(for: url) == .missing { return L10n.get("storage.externalDeleted") }
        if tabManager.diskState(for: url) == .conflict { return L10n.get("storage.externalConflict") }
        if tabManager.diskState(for: url) == .unreadable { return L10n.get("storage.readFailed") }
        if loadError != nil || tabManager.saveErrors[url] != nil { return L10n.get("storage.saveFailed") }
        if tabManager.isModified(url: url) { return L10n.get("storage.unsaved") }
        if let time = tabManager.lastSavedAt[url] {
            return L10n.get("storage.saved") + " " + time.formatted(date: .omitted, time: .shortened)
        }
        return L10n.get("storage.saved")
    }

    // MARK: - Computed Properties

    // Count once per content revision, not on cursor or layout updates.
    private func updateStatistics(_ value: String) {
        statisticsTask?.cancel()
        let request = UUID()
        statisticsRequest = request
        statisticsTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) { () -> (Int, Int, Int)? in
                var words = 0, characters = 0, lines = 1
                var inWord = false
                for character in value {
                    if characters % 8192 == 0 && Task.isCancelled { return nil }
                    characters += 1
                    if character.isNewline { lines += 1 }
                    if character.isWhitespace { inWord = false }
                    else if !inWord { words += 1; inWord = true }
                }
                return (words, characters, lines)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, statisticsRequest == request, let result else { return }
            wordCount = result.0
            characterCount = result.1
            lineCount = result.2
        }
    }

    // MARK: - Appearance projection

    private func appearanceBinding<Value: Equatable>(_ value: Value, change: @escaping (Value) -> EditorAppearanceChange) -> Binding<Value> {
        // Capture the document owner when creating a control; a delayed font-panel callback
        // must not write its selection into a different tab.
        let document = tabManager.selectedTab?.url
        return Binding(get: { value }, set: { newValue in
            guard let document, newValue != value else { return }
            do { try EditorAppearanceStore.shared.update(change(newValue), for: document) }
            catch { appearanceError = error.localizedDescription }
        })
    }

    private func loadAppearance() {
        let settings = UserSettings.shared
        let defaults = EditorAppearance(fontName: settings.editorFontName, fontSize: settings.editorFontSize,
            lineSpacing: settings.editorLineSpacing, letterSpacing: settings.editorLetterSpacing)
        do {
            let appearance = try EditorAppearanceStore.shared.effective(for: tabManager.selectedTab?.url, defaults: defaults)
            fontName = appearance.fontName
            fontSize = appearance.fontSize
            lineSpacingOption = LineSpacingOption(rawValue: appearance.lineSpacing) ?? .normal
            letterSpacing = appearance.letterSpacing
        } catch { appearanceError = error.localizedDescription }
    }

    // MARK: - Auto Save

    /// 자동 저장 타이머 설정
    private func setupAutoSaveTimer() {
        stopAutoSaveTimer()

        // 타이머 기반 자동 저장이 아닌 경우 (없음, 탭 변경 시) 타이머 사용 안 함
        guard autoSaveOption.intervalSeconds > 0 else { return }

        let interval = TimeInterval(autoSaveOption.intervalSeconds)
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            autoSaveAllModifiedTabs()
        }
    }

    /// 자동 저장 타이머 정지
    private func stopAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    /// 수정된 모든 탭 자동 저장
    private func autoSaveAllModifiedTabs() {
        tabManager.flushEditor()

        // 수정된 모든 탭을 캐시에서 저장
        for (index, tab) in tabManager.tabs.enumerated() {
            guard tabManager.isModified(url: tab.url) else { continue }
            if let cachedContent = tabManager.getCachedContent(for: tab.url) {
                _ = tabManager.saveTab(at: index, content: cachedContent)
            }
        }
    }

    /// 특정 URL의 탭이 수정되었으면 저장
    private func autoSaveIfModified(for url: URL) {
        guard let index = tabManager.findTab(with: url),
              tabManager.isModified(url: url) else { return }


        if let cachedContent = tabManager.getCachedContent(for: url) {
            _ = tabManager.saveTab(at: index, content: cachedContent)
        }
    }

    /// 사용자 편집 시 수정된 줄 표시 초기화
    private func clearModifiedLinesOnEdit() {
        if !externallyModifiedLines.isEmpty {
            externallyModifiedLines = []
        }
    }
}

// MARK: - Editor Status Bar View

struct EditorStatusBarView: View {
    let wordCount: Int
    let characterCount: Int
    let lineCount: Int
    let selectedLineRange: ClosedRange<Int>?
    let saveStatus: String

    var body: some View {
        HStack {
            Text(L10n.get("editor.lines") + " \(lineCount)")
            Text("•")
            Text("\(wordCount) \(L10n.editor.words)")
            Text("•")
            Text("\(characterCount) \(L10n.editor.characters)")

            if let range = selectedLineRange {
                Text("•")
                if range.lowerBound == range.upperBound {
                    Text(L10n.get("editor.selectedLine") + " \(range.lowerBound)")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(L10n.get("editor.selectedLines") + " \(range.lowerBound)-\(range.upperBound)")
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()

            Text(saveStatus)
        }
        .font(.system(size: 11))
        .foregroundStyle(AppColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

#Preview {
    EditorContainerView(projectManager: ProjectManager.shared)
        .environmentObject(AppCommands.shared)
}
