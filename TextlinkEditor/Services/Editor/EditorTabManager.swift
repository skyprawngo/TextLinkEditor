//
//  EditorTabManager.swift
//  TextlinkEditor
//
//  에디터 탭 관리 (열린 파일 탭 상태 관리)
//

import Foundation
import AppKit

// MARK: - Notification Names

extension Notification.Name {
    /// 에디터 탭이 변경됨 (추가, 삭제, 선택 변경 등)
    static let editorTabsDidChange = Notification.Name("editorTabsDidChange")
    static let editorDiskContentDidChange = Notification.Name("editorDiskContentDidChange")
    static let editorDiskStateDidChange = Notification.Name("editorDiskStateDidChange")
    static let editorWillPerformFileOperation = Notification.Name("editorWillPerformFileOperation")
}

/// 에디터 탭 관리자
@Observable
final class EditorTabManager: WorkspaceDocumentParticipant {
    static let shared = EditorTabManager()

    /// 현재 열린 탭들
    private(set) var tabs: [EditorTab] = []

    /// 탭별 편집 상태 (URL -> TabEditState)
    /// 텍스트, 원본 내용, 커서, 스크롤을 통합 관리
    @ObservationIgnored private var loadedDocuments: Set<URL> = []
    @ObservationIgnored private var editStates: [URL: TabEditState] = [:]

    /// 현재 선택된 탭 인덱스
    var selectedTabIndex: Int = 0 {
        didSet {
            if selectedTabIndex < 0 { selectedTabIndex = 0 }
            if selectedTabIndex >= tabs.count && tabs.count > 0 {
                selectedTabIndex = tabs.count - 1
            }
            // 선택 탭 변경 시 세션 저장
            if oldValue != selectedTabIndex {
                autoSaveSessionIfNeeded()
            }
        }
    }

    /// 세션 저장 필요 시 저장 (순환 호출 방지)
    private var isSavingSession = false
    private var sessionProjectURL: URL?
    @ObservationIgnored private var recoveryWork: DispatchWorkItem?
    @ObservationIgnored private let recoveryWriter = EditorRecoveryWriter()
    var saveErrors: [URL: String] = [:]
    var lastSavedAt: [URL: Date] = [:]
    var recoveryError: String?
    @ObservationIgnored private let observation: DocumentObservationController
    private var approvedDiscards: Set<URL> = []
    private var navigation: [URL] = []
    private var navigationIndex = -1
    private var navigating = false
    private func autoSaveSessionIfNeeded() {
        guard !isSavingSession else { return }
        guard let projectPath = sessionProjectURL else { return }
        isSavingSession = true
        saveSession(to: projectPath, asynchronously: true)
        isSavingSession = false
    }

    /// 현재 선택된 탭
    var selectedTab: EditorTab? {
        guard selectedTabIndex >= 0 && selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    private let files: WorkspaceFileCoordinator
    @ObservationIgnored private var fileEventObserver: NSObjectProtocol?
    private let recoveryDirectory: URL

    init(recoveryDirectory: URL? = nil, files: WorkspaceFileCoordinator = .shared) {
        self.files = files
        observation = DocumentObservationController(repository: files.documents, events: files.events)
    // Legacy storage identity retained for existing user data after the product rename.
        self.recoveryDirectory = recoveryDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loreweave/Recovery", isDirectory: true)
        observation.identity = { [weak self] url in
            guard let self, let index = self.findTab(with: url) else { return nil }
            return (self.tabs[index].id, self.editStates[url]?.originalContent)
        }
        observation.receive = { [weak self] url, result in
            guard let self else { return }
            switch result {
            case .success(let disk):
                if self.loadedDocuments.contains(url) { self.receiveDiskContent(disk, for: url) }
                else { self.setDiskState(.current, for: url) }
            case .failure(let error): self.receiveDiskFailure(error, for: url)
            }
        }
        files.register(self)
        fileEventObserver = files.events.observe { [weak self] event in self?.receiveFileEvent(event) }

    }

    deinit {
        stopDiskMonitoring()
        if let fileEventObserver { files.events.remove(fileEventObserver) }
    }

    func prepareForFileMove() { flushEditor() }
    func prepareForFileDeletion(at url: URL) -> Bool {
        prepareToClose(tabs.filter { DocumentFileStore.contains($0.url, in: url) })
    }
    private func receiveFileEvent(_ event: WorkspaceFileEvent) {
        switch event.change {
        case .moved(let old):
            if sessionProjectURL.map({ DocumentFileStore.contains(old, in: $0) }) == true ||
                tabs.contains(where: { DocumentFileStore.contains($0.url, in: old) }) {
                relocateTabs(from: old, to: event.url)
            }
        case .trashed: closeTabsUnder(folderURL: event.url)
        case .saved, .created, .copied, .invalidated:
            for tab in tabs where WorkspaceFileIdentity.same(tab.url, event.url) || DocumentFileStore.contains(tab.url, in: event.url) {
                requestDiskRead(for: tab.url)
            }
        case .documentContentAccepted, .documentStateChanged, .documentCopied: break
        }
    }

    // MARK: - Tab Operations

    /// 파일을 새 탭으로 열기
    func openFile(_ fileItem: FileSystemItem) {
        // 이미 열려있는 탭인지 확인
        if let existingIndex = tabs.firstIndex(where: { WorkspaceFileIdentity.same($0.fileItem.url, fileItem.url) }) {
            selectedTabIndex = existingIndex
            notifyTabsChanged()
            return
        }

        // 새 탭 생성
        let newTab = EditorTab(fileItem: fileItem)
        tabs.append(newTab)
        selectedTabIndex = tabs.count - 1
        notifyTabsChanged()
    }

    /// 탭 닫기
    /// - Parameters:
    ///   - index: 닫을 탭 인덱스
    ///   - force: true이면 수정 여부와 관계없이 강제 닫기
    func closeTab(at index: Int, force: Bool = false) {
        guard tabs.indices.contains(index) else { return }
        let id = tabs[index].id
        guard force || prepareToClose([tabs[index]]) else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        removeCachedContent(for: tabs[index].url)
        tabs.remove(at: index)
        if tabs.isEmpty { selectedTabIndex = 0 }
        else if selectedTabIndex >= tabs.count { selectedTabIndex = tabs.count - 1 }
        else if index < selectedTabIndex { selectedTabIndex -= 1 }
        notifyTabsChanged()
        persistClosedTabs()
    }

    /// 특정 폴더 하위의 모든 파일 탭 닫기
    /// - Parameter folderURL: 폴더 URL
    func closeTabsUnder(folderURL: URL) {
        let removed = tabs.filter { DocumentFileStore.contains($0.url, in: folderURL) }
        guard !removed.isEmpty else { return }
        let selectedID = selectedTab?.id
        let previousIndex = selectedTabIndex
        for tab in removed { removeCachedContent(for: tab.url) }
        // Publish only the final selection. Per-tab notifications can select
        // another document in the folder that has already been trashed.
        let ids = Set(removed.map(\.id))
        tabs.removeAll { ids.contains($0.id) }
        selectedTabIndex = tabs.firstIndex(where: { $0.id == selectedID })
            ?? max(0, min(previousIndex, tabs.count - 1))
        notifyTabsChanged()
        persistClosedTabs()
    }

    /// 특정 탭 선택
    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabIndex = index
        notifyTabsChanged()
    }

    /// 새 빈 탭 생성 (제목 없음)
    func createNewTab() {
        // 임시 빈 파일용 FileSystemItem 생성
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Untitled-\(UUID().uuidString.prefix(8)).md")
        let tempItem = FileSystemItem(url: tempURL, isDirectory: false)
        tempItem.name = L10n.editor.untitled

        let newTab = EditorTab(fileItem: tempItem, isModified: true)
        tabs.append(newTab)
        selectedTabIndex = tabs.count - 1
        notifyTabsChanged()
    }

    /// 탭의 수정 상태 변경
    func setModified(_ isModified: Bool, at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        tabs[index].isModified = isModified
    }

    /// 현재 탭의 내용 저장
    func saveCurrentTab(content: String) -> Bool {
        guard selectedTab != nil else { return false }
        return saveTab(at: selectedTabIndex, content: content)
    }

    /// 특정 탭의 내용 저장
    func saveTab(at index: Int, content: String) -> Bool {
        guard tabs.indices.contains(index), let state = editStates[tabs[index].url] else { return false }
        let url = tabs[index].url
        observation.cancelRead(url)
        do {
            // Always verify at the write boundary, even before a watcher has delivered an event.
            let disk = try files.documents.read(url)
            let decision = DocumentReconciliation.decide(base: state.originalContent, draft: content, disk: disk)
            if content == state.originalContent, decision == .adoptDisk {
                receiveDiskContent(disk, for: url)
                return true
            }
            guard decision != .conflict else {
                setDiskState(.conflict, for: url)
                throw DocumentFileStore.Failure.conflict
            }
            if let project = sessionProjectURL, content != state.originalContent,
               url.standardizedFileURL.path.hasPrefix(project.standardizedFileURL.path + "/") {
                _ = try VersionHistoryStore.snapshot(projectURL: project, documentURL: url, content: state.originalContent, reason: "versions.beforeSave")
            }
            try files.documents.save(content, at: url, expected: state.originalContent)
            editStates[url]?.content = content
            editStates[url]?.markAsSaved()
            setDiskState(.current, for: url)
            tabs[index].isModified = false
            tabs[index].justSaved = true
            saveErrors[url] = nil
            lastSavedAt[url] = Date()
            autoSaveSessionIfNeeded()
            let id = tabs[index].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if let i = self?.tabs.firstIndex(where: { $0.id == id }) { self?.tabs[i].justSaved = false }
            }
            return true
        } catch {
            if isMissingFileError(error) { setDiskState(.missing, for: url) }
            else if case DocumentFileStore.Failure.conflict = error { setDiskState(.conflict, for: url) }
            saveErrors[url] = error is DocumentFileStore.Failure ? L10n.get("storage.conflict") : error.localizedDescription
            autoSaveSessionIfNeeded()
            return false
        }
    }

    private func ownedURL(_ url: URL) -> URL {
        if editStates[url] != nil { return url }
        return tabs.first(where: { WorkspaceFileIdentity.same($0.url, url) })?.url ?? url
    }

    /// URL로 탭의 수정 상태 확인
    func isModified(url: URL) -> Bool {
        let url = ownedURL(url)
        return editStates[url]?.isModified ?? false
    }

    // MARK: - Edit State Management (통합 캐시 관리)

    /// URL의 전체 편집 상태 가져오기
    func getEditState(for url: URL) -> TabEditState? {
        let url = ownedURL(url)
        return editStates[url]
    }

    /// URL의 편집 상태 설정 (없으면 생성)
    func setEditState(_ state: TabEditState, for url: URL) {
        let url = ownedURL(url)
        editStates[url] = state
        loadedDocuments.insert(url)
        if let index = findTab(with: url) { tabs[index].isModified = state.isModified }
        synchronizeDiskMonitors()
    }

    /// URL의 편집 상태 삭제
    func removeEditState(for url: URL) {
        let url = ownedURL(url)
        editStates.removeValue(forKey: url)
        loadedDocuments.remove(url)
        observation.cancelRead(url)
        observation.remove(url)
    }

    /// URL로 캐시된 탭 내용 가져오기
    func getCachedContent(for url: URL) -> String? {
        let url = ownedURL(url)
        return editStates[url]?.content
    }

    /// 탭 내용을 캐시에 저장 (편집 상태가 없으면 생성)
    func setCachedContent(_ content: String, for url: URL) {
        let url = ownedURL(url)
        guard findTab(with: url) != nil else { return }
        if editStates[url] != nil {
            editStates[url]?.content = content
        } else {
            editStates[url] = TabEditState(content: content, originalContent: content)
        }
        if let index = findTab(with: url) {
            let modified = editStates[url]?.isModified ?? false
            if tabs[index].isModified != modified { tabs[index].isModified = modified }
        }
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoSaveSessionIfNeeded() }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 원본 콘텐츠 설정 (파일 로드 시 사용)
    func setOriginalContent(_ content: String, for url: URL) {
        let url = ownedURL(url)
        loadedDocuments.insert(url)
        if editStates[url] != nil {
            editStates[url]?.originalContent = content
        } else {
            editStates[url] = TabEditState(content: content, originalContent: content)
        }
        // 탭의 isModified 상태 동기화
        if let index = findTab(with: url) {
            tabs[index].isModified = editStates[url]?.isModified ?? false
        }
    }

    /// 캐시에서 탭 내용 삭제 (레거시 호환)
    func removeCachedContent(for url: URL) {
        let url = ownedURL(url)
        removeEditState(for: url)
    }

    /// URL로 캐시된 커서 위치 가져오기
    func getCachedCursorPosition(for url: URL) -> (line: Int, column: Int)? {
        let url = ownedURL(url)
        return editStates[url]?.cursorPosition
    }

    /// 커서 위치를 캐시에 저장
    func setCachedCursorPosition(line: Int, column: Int, for url: URL) {
        let url = ownedURL(url)
        if editStates[url] != nil {
            editStates[url]?.cursorPosition = (line, column)
        } else {
            editStates[url] = TabEditState(cursorPosition: (line, column))
        }
    }

    /// 모든 탭 닫기
    @discardableResult
    func closeAllTabs(force: Bool = false) -> Bool {
        guard force || prepareToClose(tabs) else { return false }
        editStates.removeAll()
        loadedDocuments.removeAll()
        tabs.removeAll()
        selectedTabIndex = 0
        notifyTabsChanged()
        persistClosedTabs()
        return true
    }

    /// 현재 탭 외 모든 탭 닫기
    func closeOtherTabs(except index: Int) {
        guard tabs.indices.contains(index) else { return }
        let keep = tabs[index]
        guard prepareToClose(tabs.filter { $0.id != keep.id }) else { return }
        for tab in tabs where tab.id != keep.id { removeEditState(for: tab.url) }
        tabs = [keep]
        selectedTabIndex = 0
        notifyTabsChanged()
        persistClosedTabs()
    }

    /// URL로 탭 찾기
    func findTab(with url: URL) -> Int? {
        tabs.firstIndex(where: { WorkspaceFileIdentity.same($0.fileItem.url, url) })
    }

    /// 탭이 비어있는지 확인
    var isEmpty: Bool {
        tabs.isEmpty
    }

    /// 탭 개수
    var count: Int {
        tabs.count
    }

    // MARK: - Navigation

    /// 다음 탭 선택
    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        selectedTabIndex = (selectedTabIndex + 1) % tabs.count
    }

    /// 이전 탭 선택
    func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        selectedTabIndex = selectedTabIndex > 0 ? selectedTabIndex - 1 : tabs.count - 1
    }

    /// 탭 순서 이동
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count else { return }
        guard destinationIndex >= 0 && destinationIndex < tabs.count else { return }
        guard sourceIndex != destinationIndex else { return }

        let movedTab = tabs.remove(at: sourceIndex)
        tabs.insert(movedTab, at: destinationIndex)

        // 선택된 탭 인덱스 조정
        if selectedTabIndex == sourceIndex {
            selectedTabIndex = destinationIndex
        } else if sourceIndex < selectedTabIndex && destinationIndex >= selectedTabIndex {
            selectedTabIndex -= 1
        } else if sourceIndex > selectedTabIndex && destinationIndex <= selectedTabIndex {
            selectedTabIndex += 1
        }

        notifyTabsChanged()
    }

    /// 현재 탭 닫기
    func closeCurrentTab() {
        closeTab(at: selectedTabIndex)
    }

    /// 현재 탭 저장 (EditorView에서 내용을 전달받아 저장)
    /// 주의: EditorView와 연동 필요
    func saveCurrentTab() {
        flushEditor()
        guard let tab = selectedTab, let content = getCachedContent(for: tab.url) else { return }
        if !saveTab(at: selectedTabIndex, content: content) {
            if diskState(for: tab.url).requiresCopy { offerConflictCopy(for: tab) }
            else { showSaveError(for: tab.url) }
        }
    }

    var canGoBack: Bool { navigation.indices.contains(navigationIndex - 1) }
    var canGoForward: Bool { navigation.indices.contains(navigationIndex + 1) }

    func goBack() { navigate(to: navigationIndex - 1) }
    func goForward() { navigate(to: navigationIndex + 1) }
    private func navigate(to index: Int) {
        guard navigation.indices.contains(index) else { return }
        navigating = true
        navigationIndex = index
        openFile(FileSystemItem(url: navigation[index], isDirectory: false))
        navigating = false
    }

    func flushEditor() {
        NotificationCenter.default.post(name: .editorWillPerformFileOperation, object: nil)
    }

    /// Give the workspace agent the same text the user sees; never ignore a failed save.
    func validateAIApplication(project: URL) throws {
        var composing = false
        let check: (Bool) -> Void = { composing = composing || $0 }
        NotificationCenter.default.post(name: .editorWillPerformFileOperation, object: nil,
                                       userInfo: ["checkComposition": check])
        guard !composing else { throw NSError(domain: "AIWorkspaceEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.get("storage.conflict")]) }
        flushEditor()
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !tabs.contains(where: {
            $0.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) && isModified(url: $0.url)
        }) else { throw NSError(domain: "AIWorkspaceEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.get("storage.conflict")]) }
    }

    func collaborationDrafts(project: URL) -> [String: String] {
        flushEditor()
        let prefix = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var result: [String: String] = [:]
        for tab in tabs {
            let path = tab.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix), isModified(url: tab.url), let text = getCachedContent(for: tab.url) else { continue }
            result[String(path.dropFirst(prefix.count))] = text
        }
        return result
    }

    func prepareForAIWorkspaceEdit(project: URL) throws {
        flushEditor()
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (index, tab) in tabs.enumerated() where tab.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) {
            guard isModified(url: tab.url) else { continue }
            guard let content = getCachedContent(for: tab.url), saveTab(at: index, content: content) else {
                throw NSError(domain: "AIWorkspaceEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.get("storage.conflict")])
            }
        }
    }

    /// Resolve all decisions before removing any drafts. Cancel keeps the workspace intact.
    func prepareToClose(_ candidates: [EditorTab]) -> Bool {
        flushEditor()
        approvedDiscards.removeAll()
        var discard: [URL] = []
        for candidate in candidates {
            guard let index = tabs.firstIndex(where: { $0.id == candidate.id }) else { continue }
            let url = tabs[index].url
            refreshDiskStateBeforeClose(for: url)
            if diskState(for: url).requiresCopy {
                discard.append(url)
                continue
            }
            guard tabs[index].isModified else { continue }
            let alert = NSAlert()
            alert.messageText = L10n.get("app.quit.saveChangesTitle")
            alert.informativeText = String(format: L10n.get("app.quit.saveChangesMessage"), candidate.title)
            alert.addButton(withTitle: L10n.get("app.quit.save"))
            alert.addButton(withTitle: L10n.get("app.quit.dontSave"))
            alert.addButton(withTitle: L10n.common.cancel)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let content = getCachedContent(for: url), saveTab(at: index, content: content) else {
                    showSaveError(for: url)
                    return false
                }
            case .alertSecondButtonReturn: discard.append(url)
            default: return false
            }
        }
        approvedDiscards = Set(discard)
        return true
    }

    func showSaveError(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.get("storage.saveFailed")
        alert.informativeText = saveErrors[url] ?? L10n.get("storage.saveFailed")
        alert.addButton(withTitle: L10n.common.confirm)
        alert.runModal()
    }

    func saveAs() {
        flushEditor()
        guard let tab = selectedTab, let content = getCachedContent(for: tab.url) else { return }
        refreshDiskStateBeforeClose(for: tab.url)
        if diskState(for: tab.url).requiresCopy {
            presentConflictCopyPanel(for: tab)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.title
        panel.directoryURL = tab.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if WorkspaceFileIdentity.same(target, tab.url) {
                if !saveTab(at: selectedTabIndex, content: content) {
                    if diskState(for: tab.url).requiresCopy { offerConflictCopy(for: tab) }
                    else { showSaveError(for: tab.url) }
                }
                return
            }
            guard !tabs.contains(where: { WorkspaceFileIdentity.same($0.url, target) }) else { throw NSError(domain: "AIWorkspaceEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.get("storage.conflict")]) }
            if FileManager.default.fileExists(atPath: target.path) {
                let base = try files.documents.read(target)
                try files.documents.save(content, at: target, expected: base)
            } else { try files.documents.create(content, at: target) }
            files.events.publish(.init(url: target, change: .documentCopied(from: tab.url)))
            relocateTabs(from: tab.url, to: target)
            if let i = findTab(with: target) {
                editStates[target]?.markAsSaved()
                tabs[i].isModified = false
                saveErrors[target] = nil
                lastSavedAt[target] = Date()
            }
            autoSaveSessionIfNeeded()
        } catch {
            saveErrors[tab.url] = error.localizedDescription
            showSaveError(for: tab.url)
        }
    }

    func relocateTabs(from old: URL, to new: URL) {
        if let project = sessionProjectURL {
            do {
                try VersionHistoryStore.relocate(projectURL: project, from: old, to: new)
                try WritingWorkspaceStore(projectURL: project).relocatePaths(old: old, new: new)
            } catch { recoveryError = error.localizedDescription }
        }
        for i in tabs.indices {
            let source = tabs[i].url
            guard let target = WorkspaceFileIdentity.relocated(source, from: old, to: new) else { continue }
            let oldItem = tabs[i].fileItem
            tabs[i].fileItem = FileSystemItem(url: target, isDirectory: oldItem.isDirectory)
            observation.remove(source)
            tabs[i].diskState = .current
            if loadedDocuments.remove(source) != nil { loadedDocuments.insert(target) }
            editStates[target] = editStates.removeValue(forKey: source)
            saveErrors[target] = saveErrors.removeValue(forKey: source)
            lastSavedAt[target] = lastSavedAt.removeValue(forKey: source)
        }
        notifyTabsChanged()
    }

    // MARK: - Notifications

    /// 탭 변경 알림 전송 (AppKit 컴포넌트 업데이트용)
    private func notifyTabsChanged() {
        synchronizeDiskMonitors()
        if !navigating, let url = selectedTab?.url, (navigation.indices.contains(navigationIndex) ? navigation[navigationIndex] : nil) != url {
            if navigationIndex + 1 < navigation.count { navigation = Array(navigation.prefix(navigationIndex + 1)) }
            navigation.append(url)
            navigationIndex = navigation.count - 1
        }
        NotificationCenter.default.post(name: .editorTabsDidChange, object: nil)
        // 탭 변경 시 세션 자동 저장
        autoSaveSessionIfNeeded()
    }

    // MARK: - Session Persistence

    /// 세션 상태 파일명
    private static let sessionFileName = "editor-session.json"
    /// 에디터 설정 파일명
    private static let editorSettingsFileName = "editor-settings.json"

    /// 프로젝트의 데이터 폴더 경로
    private func dataFolderURL(for projectURL: URL) -> URL {
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let dataFolderName = ".\(projectName).\(ProjectManager.dataFolderExtension)"
        return projectURL.appendingPathComponent(dataFolderName)
    }

    /// 프로젝트의 세션 파일 경로
    private func sessionFileURL(for projectURL: URL) -> URL {
        return dataFolderURL(for: projectURL).appendingPathComponent(Self.sessionFileName)
    }

    /// 프로젝트의 에디터 설정 파일 경로
    private func editorSettingsFileURL(for projectURL: URL) -> URL {
        return dataFolderURL(for: projectURL).appendingPathComponent(Self.editorSettingsFileName)
    }

    /// 현재 탭 상태를 프로젝트에 저장
    func saveSession(to projectURL: URL, omittingApprovedDiscards: Bool = false, asynchronously: Bool = false) {
        // 탭 상태를 상대 경로로 변환
        let tabStates = tabs.compactMap { tab -> TabState? in
            if omittingApprovedDiscards && approvedDiscards.contains(tab.url) { return nil }
            let filePath = tab.url.path
            let projectPath = projectURL.path

            // 프로젝트 폴더 내 파일인지 확인
            let isExternal = !filePath.hasPrefix(projectPath + "/")

            // 상대 경로 계산
            let relativePath = isExternal ? tab.url.lastPathComponent : String(filePath.dropFirst(projectPath.count + 1))
            // 커서 위치 가져오기 (editStates에서)
            let cursor = editStates[tab.url]?.cursorPosition ?? (0, 0)
            var snapshot = TabState(relativePath: relativePath, isModified: tab.isModified, cursorLine: cursor.0, cursorColumn: cursor.1)
            if isExternal { snapshot.externalURL = tab.url }
            if let state = editStates[tab.url], (tab.isModified || tab.diskState == .missing),
               !(omittingApprovedDiscards && approvedDiscards.contains(tab.url)) {
                snapshot.draftContent = state.content
                snapshot.baseContent = state.originalContent
            }
            return snapshot
        }

        let sessionState = EditorSessionState(
            tabs: tabStates,
            selectedTabIndex: selectedTabIndex
        )

        let sessionFile = sessionFileURL(for: projectURL)

        let store = EditorSessionStore(recoveryDirectory: recoveryDirectory)
        let portableTabs = tabStates.filter { $0.externalURL == nil }
        let selectedURL = selectedTab?.url
        let portableIndex = portableTabs.firstIndex { projectURL.appendingPathComponent($0.relativePath) == selectedURL } ?? 0
        let portable = EditorSessionState(tabs: portableTabs, selectedTabIndex: portableIndex)
        // Immutable snapshots cross the queue; AppKit and observable state stay on main.
        let write: () -> String? = {
            do {
                try store.write(local: sessionState, portable: portable, project: projectURL, portableURL: sessionFile)
                return nil
            } catch { return error.localizedDescription }
        }
        recoveryWriter.write(asynchronously: asynchronously, operation: write) { [weak self] error in
            self?.recoveryError = error
        }
    }

    /// 프로젝트에서 탭 상태 복원
    func restoreSession(from projectURL: URL) {
        stopDiskMonitoring()
        recoveryWork?.cancel()
        recoveryWriter.invalidateAndWait()
        isSavingSession = true
        defer { isSavingSession = false }
        sessionProjectURL = projectURL
        recoveryError = nil
        navigation.removeAll()
        navigationIndex = -1
        editStates.removeAll()
        loadedDocuments.removeAll()
        tabs.removeAll()
        selectedTabIndex = 0
        let loaded = EditorSessionStore(recoveryDirectory: recoveryDirectory).load(project: projectURL, portableURL: sessionFileURL(for: projectURL))
        recoveryError = loaded.error
        let trustedLocal = loaded.trustedLocal
        guard let session = loaded.session else { return }
        for entry in session.tabs {
            let url = (entry.externalURL ?? projectURL.appendingPathComponent(entry.relativePath)).standardizedFileURL
            guard ((trustedLocal && entry.externalURL != nil) || (entry.externalURL == nil && DocumentFileStore.contains(url, in: projectURL))),
                  FileManager.default.fileExists(atPath: url.path) || entry.draftContent != nil else { continue }
            let tab = EditorTab(fileItem: FileSystemItem(url: url, isDirectory: false), isModified: entry.draftContent != nil)
            tabs.append(tab)
            if let draft = entry.draftContent, let base = entry.baseContent {
                editStates[url] = TabEditState(content: draft, originalContent: base, cursorPosition: (entry.cursorLine, entry.cursorColumn))
                loadedDocuments.insert(url)
            } else {
                setCachedCursorPosition(line: entry.cursorLine, column: entry.cursorColumn, for: url)
            }
        }
        selectedTabIndex = max(0, min(session.selectedTabIndex, tabs.count - 1))
        synchronizeDiskMonitors()
        NotificationCenter.default.post(name: .editorTabsDidChange, object: nil)
    }

    // MARK: - Editor Settings Persistence

    /// 에디터 설정을 프로젝트에 저장
    func saveEditorSettings(_ settings: ProjectEditorSettings, to projectURL: URL) {
        let settingsFile = editorSettingsFileURL(for: projectURL)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(settings)
            try data.write(to: settingsFile)
        } catch {
            print("Failed to save editor settings: \(error)")
        }
    }

    /// 프로젝트에서 에디터 설정 로드
    func loadEditorSettings(from projectURL: URL) -> ProjectEditorSettings? {
        let settingsFile = editorSettingsFileURL(for: projectURL)

        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: settingsFile)
            let settings = try JSONDecoder().decode(ProjectEditorSettings.self, from: data)
            return settings
        } catch {
            print("Failed to load editor settings: \(error)")
            return nil
        }
    }

    // MARK: - External document synchronization

    func readDocument(at url: URL) async throws -> String { try await files.documents.readSnapshot(url) }

    func hasLoadedContent(for url: URL) -> Bool { loadedDocuments.contains(ownedURL(url)) }

    func diskState(for url: URL) -> DocumentDiskState {
        findTab(with: url).map { tabs[$0].diskState } ?? .current
    }

    private func setDiskState(_ state: DocumentDiskState, for url: URL) {
        guard let index = findTab(with: url), tabs[index].diskState != state else { return }
        tabs[index].diskState = state
        files.events.publish(.init(url: url, change: .documentStateChanged))
        autoSaveSessionIfNeeded()
    }

    /// Used by both the event reader and deterministic regression fixtures. Never advances
    /// the base underneath an unsaved draft. Flush only when an actual competing version exists.
    func receiveDiskContent(_ disk: String, for url: URL) {
        let url = ownedURL(url)
        guard let old = editStates[url], findTab(with: url) != nil else { return }
        if disk != old.originalContent, selectedTab?.url == url { flushEditor() }
        guard var state = editStates[url], findTab(with: url) != nil else { return }
        let decision = DocumentReconciliation.decide(base: state.originalContent, draft: state.content, disk: disk)
        if decision == .unchanged {
            setDiskState(.current, for: url)
            saveErrors[url] = nil
            return
        }
        if decision == .conflict {
            setDiskState(.conflict, for: url)
            return
        }
        let contentChanged = state.content != disk
        state.content = disk
        state.originalContent = disk
        editStates[url] = state
        if let index = findTab(with: url) { tabs[index].isModified = false }
        setDiskState(.current, for: url)
        saveErrors[url] = nil
        if contentChanged {
            files.events.publish(.init(url: url, change: .documentContentAccepted))
        }
        autoSaveSessionIfNeeded()
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
    }

    private func receiveDiskFailure(_ error: Error, for url: URL) {
        if case DocumentFileStore.Failure.conflict = error {
            // A writer changed the file during the read. Keep the last valid state and retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.files.events.publish(.init(url: url, change: .invalidated))
            }
        } else if isMissingFileError(error) { setDiskState(.missing, for: url) }
        else { setDiskState(.unreadable, for: url) }
    }

    private func refreshDiskStateBeforeClose(for url: URL) {
        observation.cancelRead(url)
        do { receiveDiskContent(try files.documents.read(url), for: url) }
        catch { receiveDiskFailure(error, for: url) }
    }

    func refreshExternalDocuments() {
        synchronizeDiskMonitors()
        observation.refresh()
    }
    private func requestDiskRead(for url: URL) { observation.requestRead(url) }
    private func synchronizeDiskMonitors() { observation.synchronize(Set(tabs.map(\.url))) }
    private func stopDiskMonitoring() { observation.stop() }

    private func persistClosedTabs() {
        recoveryWork?.cancel()
        if let project = sessionProjectURL { saveSession(to: project) }
    }

    private func offerConflictCopy(for tab: EditorTab) {
        let alert = NSAlert()
        alert.messageText = L10n.get("storage.externalSaveTitle")
        alert.informativeText = L10n.get("storage.externalSaveMessage")
        alert.addButton(withTitle: L10n.get("storage.saveCopy"))
        alert.addButton(withTitle: L10n.common.cancel)
        if alert.runModal() == .alertFirstButtonReturn { presentConflictCopyPanel(for: tab) }
    }

    private func presentConflictCopyPanel(for tab: EditorTab) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.url.deletingPathExtension().lastPathComponent + "-copy." + tab.url.pathExtension
        panel.directoryURL = tab.url.deletingLastPathComponent()
        while panel.runModal() == .OK, let target = panel.url {
            do {
                flushEditor()
                try saveConflictCopy(from: tab.url, to: target)
                return
            } catch {
                saveErrors[tab.url] = error.localizedDescription
                showSaveError(for: tab.url)
            }
        }
    }

    /// Exclusive creation is intentional: never overwrite the source, another open document,
    /// or an existing destination, even if a save panel offered a Replace button.
    func saveConflictCopy(from source: URL, to target: URL) throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != target.resolvingSymlinksInPath().standardizedFileURL,
              !tabs.contains(where: { $0.url.standardizedFileURL == target.standardizedFileURL }),
              let content = getCachedContent(for: source) else { throw DocumentFileStore.Failure.conflict }
        try files.documents.create(content, at: target)
        files.events.publish(.init(url: target, change: .documentCopied(from: source)))
        relocateTabs(from: source, to: target)
        if let index = findTab(with: target) {
            editStates[target]?.markAsSaved()
            tabs[index].isModified = false
            tabs[index].diskState = .current
            saveErrors[target] = nil
            lastSavedAt[target] = Date()
        }
        persistClosedTabs()
    }
}
