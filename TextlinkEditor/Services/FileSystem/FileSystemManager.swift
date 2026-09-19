//
//  FileSystemManager.swift
//  TextlinkEditor
//
//  파일 시스템 관리 서비스 (파일/폴더 CRUD 및 감시)
//

import Foundation
import AppKit
import Combine

@Observable
final class FileSystemManager {
    static let shared = FileSystemManager()

    /// 프로젝트 루트 항목
    var projectRoot: FileSystemItem?

    /// 사이드바에서 현재 선택된 항목
    var selectedItem: FileSystemItem?

    /// 파일 시스템 변경 감시자
    private let files: WorkspaceFileCoordinator
    private var fileEventObserver: NSObjectProtocol?
    var operationError: String?
    var revision = 0
    private var directoryWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// 프로젝트 루트 URL
    private(set) var projectRootURL: URL?

    /// 새 파일 생성 시 사용할 디렉토리 (우선순위: 선택된 파일의 부모 디렉토리 > 선택된 폴더 > 루트)
    var targetDirectoryForNewFile: FileSystemItem? {
        guard let selected = selectedItem else {
            return projectRoot
        }

        if selected.isDirectory {
            return selected
        } else {
            // 파일이 선택된 경우 부모 디렉토리 찾기
            return findParent(of: selected) ?? projectRoot
        }
    }

    init(files: WorkspaceFileCoordinator = .shared) {
        self.files = files
        fileEventObserver = files.events.observe { [weak self] event in
            guard let self, let root = self.projectRootURL,
                  DocumentFileStore.contains(event.url, in: root) || {
                      if case .moved(let old) = event.change { return DocumentFileStore.contains(old, in: root) }
                      return false
                  }() else { return }
            switch event.change {
            case .documentContentAccepted, .saved: break
            default:
                // Coalesce with the command's own item updates; never refresh the tree inside a mutation.
                DispatchQueue.main.async { [weak self] in
                    guard self?.projectRootURL == root else { return }
                    self?.refreshProject()
                }
            }
        }
    }

    deinit { if let fileEventObserver { files.events.remove(fileEventObserver) }; stopWatching() }

    // MARK: - 프로젝트 초기화

    /// 프로젝트 열기 및 루트 로드
    func initializeProject(at url: URL) {
        stopWatching()
        projectRootURL = url

        // 프로젝트 루트 항목 생성
        let rootItem = FileSystemItem(url: url, isDirectory: true)
        rootItem.isExpanded = true
        projectRoot = rootItem

        // 루트 자식 로드
        loadChildren(of: rootItem)

        // 파일 감시 시작
        startWatching(at: url)
    }

    /// 프로젝트 닫기 및 리소스 정리
    func closeProject() {
        stopWatching()
        projectRoot = nil
        projectRootURL = nil
    }

    // MARK: - 디렉토리 내용 로드

    /// 프로젝트 루트 로드
    func loadProjectRoot() {
        guard let rootItem = projectRoot else { return }
        loadChildren(of: rootItem)
    }

    /// 특정 항목의 자식 로드 (기존 항목 유지하며 증분 업데이트)
    func loadChildren(of item: FileSystemItem) {
        guard item.isDirectory else { return }

        do {
            let contents = try files.children(at: item.url)

            var newChildren: [FileSystemItem] = []
            var folderCount = 0
            var fileCount = 0
            let folderIcons: [String: String]
            if let projectRootURL {
                do { folderIcons = try FolderAppearanceStore(projectURL: projectRootURL).load() }
                catch { folderIcons = [:]; operationError = error.localizedDescription }
            } else {
                folderIcons = [:]
            }
            let existingChildren = item.children ?? []
            // URL 비교 시 standardizedFileURL.path 사용 (유니코드 정규화 문제 해결)
            let existingByPath = Dictionary(uniqueKeysWithValues: existingChildren.map {
                (WorkspaceFileIdentity.key($0.url), $0)
            })

            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let standardizedPath = WorkspaceFileIdentity.key(url)
                // 기존 항목이 있으면 재사용 (상태 유지)
                if let existing = existingByPath[standardizedPath] {
                    newChildren.append(existing)
                } else {
                    // 새 항목만 생성
                    let child = FileSystemItem(url: url, isDirectory: isDirectory, parent: item)
                    newChildren.append(child)
                }

                if isDirectory {
                    folderCount += 1
                } else {
                    fileCount += 1
                }
            }

            if let projectRootURL {
                let store = FolderAppearanceStore(projectURL: projectRootURL)
                for child in newChildren where child.isDirectory {
                    let key = try? store.pathKey(for: child.url)
                    child.customFolderIcon = key.flatMap { folderIcons[$0] }.flatMap(FolderIcon.init(rawValue:))?.rawValue
                }
            }
            item.children = newChildren
            item.childFolderCount = folderCount
            item.childFileCount = fileCount
            item.sortChildren()
            // A child is displayed before it is expanded, so obtain its direct counts
            // now without materializing its children or changing its expansion state.
            for child in newChildren where child.isDirectory {
                loadDirectChildCounts(of: child)
            }
            revision += 1
            watchDirectory(item)
        } catch {
            print("Failed to load directory contents: \(error)")
            operationError = error.localizedDescription
        }
    }

    /// Loads only the immediate counts used by the sidebar badge. This intentionally
    /// does not populate `children`, preserving the tree's lazy expansion behavior.
    private func loadDirectChildCounts(of item: FileSystemItem) {
        do {
            let contents = try files.children(at: item.url)
            var folderCount = 0
            var fileCount = 0
            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true {
                    folderCount += 1
                } else {
                    fileCount += 1
                }
            }
            item.childFolderCount = folderCount
            item.childFileCount = fileCount
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// 항목 펼치기/접기 토글
    func toggleExpand(_ item: FileSystemItem) {
        guard item.isDirectory else { return }

        // 먼저 UI 상태 즉시 변경 (반응성 향상)
        item.isExpanded.toggle()

        // 펼칠 때만 자식 로드 (접을 때는 기존 데이터 유지)
        if item.isExpanded {
            // 자식이 없거나 비어있으면 로드
            loadChildren(of: item)
        }
    }

    // MARK: - 파일/폴더 생성

    func setFolderIcon(_ icon: FolderIcon?, for item: FileSystemItem) throws {
        guard item.isDirectory, let projectRootURL else { throw CocoaError(.fileNoSuchFile) }
        try FolderAppearanceStore(projectURL: projectRootURL).setIcon(icon, for: item.url)
        item.customFolderIcon = icon?.rawValue
        revision += 1
    }

    private func relocateFolderAppearance(from source: URL, to destination: URL, copying: Bool = false) {
        guard let projectRootURL else { return }
        do { try FolderAppearanceStore(projectURL: projectRootURL).relocate(from: source, to: destination, copying: copying) }
        catch { operationError = error.localizedDescription }
    }

    /// 새 폴더 생성
    @discardableResult
    func createFolder(named name: String, in parent: FileSystemItem) -> FileSystemItem? {
        guard parent.isDirectory else { return nil }

        let newURL = parent.url.appendingPathComponent(name)

        do {
            try files.createDirectory(at: newURL)
            let newItem = FileSystemItem(url: newURL, isDirectory: true, parent: parent)

            if parent.children == nil {
                parent.children = []
            }
            parent.children?.append(newItem)
            parent.childFolderCount += 1
            parent.sortChildren()
            revision += 1
            return newItem
        } catch {
            operationError = error.localizedDescription
            return nil
        }
    }

    /// 새 파일 생성
    @discardableResult
    func createFile(named name: String, in parent: FileSystemItem, content: String = "") -> FileSystemItem? {
        guard parent.isDirectory else { return nil }

        let newURL = parent.url.appendingPathComponent(name)

        do {
            try DocumentFileStore.validateName(name)
            try files.documents.create(content, at: newURL)
            let newItem = FileSystemItem(url: newURL, isDirectory: false, parent: parent)

            if parent.children == nil {
                parent.children = []
            }
            parent.children?.append(newItem)
            parent.childFileCount += 1
            parent.sortChildren()
            revision += 1
            return newItem
        } catch {
            operationError = error.localizedDescription
            return nil
        }
    }

    // MARK: - 이름 변경

    /// 항목 이름 변경
    @discardableResult
    func rename(_ item: FileSystemItem, to newName: String) -> Bool {
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)

        do {
            try DocumentFileStore.validateName(newName)
            try files.move(from: item.url, to: newURL)
            if item.isDirectory { relocateFolderAppearance(from: item.url, to: newURL) }

            // FileSystemItem은 클래스이므로 URL을 직접 변경할 수 없음
            // 부모의 children을 새로고침해야 함
            if let parent = item.parent {
                loadChildren(of: parent)
            }

            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    // MARK: - 삭제

    /// 항목 삭제
    @discardableResult
    func delete(_ item: FileSystemItem) -> Bool {
        // macOS 파일 시스템의 유니코드 정규화 (NFD) 문제 해결
        // item.url이 실제 파일 시스템의 URL과 다를 수 있으므로 standardizedFileURL 사용
        let fileURL = item.url.standardizedFileURL

        // 파일이 실제로 존재하는지 확인
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            stopWatching(under: fileURL)
            print("File does not exist at path: \(fileURL.path)")
            // 부모의 children에서 제거 (UI 정리)
            if let parent = item.parent {
                parent.children?.removeAll { $0.id == item.id }
                decrementChildCount(for: item, in: parent)
            }
            return true // 이미 없으므로 성공으로 처리
        }

        do {
            guard try files.trash(fileURL) else { return false }
            stopWatching(under: fileURL)
            if item.isDirectory, let projectRootURL {
                do { try FolderAppearanceStore(projectURL: projectRootURL).remove(for: fileURL) }
                catch { operationError = error.localizedDescription }
            }

            // 부모의 children에서 제거
            if let parent = item.parent {
                parent.children?.removeAll { $0.id == item.id }
                decrementChildCount(for: item, in: parent)
            }

            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    // MARK: - 이동 (드래그 앤 드롭)

    /// 수정된 파일 이동 전 확인 다이얼로그 결과
    enum ModifiedFileMoveResult {
        case saveAndMove
        case cancel
    }

    /// 이름 충돌 다이얼로그 결과
    enum NameConflictResult {
        case rename(String)  // 새 이름으로 이동
        case cancel
    }

    /// 대상 디렉토리에 같은 이름의 파일이 있는지 확인
    func fileExists(named name: String, in destination: FileSystemItem) -> Bool {
        let targetURL = destination.url.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: targetURL.path)
    }

    private func decrementChildCount(for item: FileSystemItem, in parent: FileSystemItem) {
        if item.isDirectory {
            parent.childFolderCount = max(0, parent.childFolderCount - 1)
        } else {
            parent.childFileCount = max(0, parent.childFileCount - 1)
        }
    }

    /// 항목 이동
    @discardableResult
    func move(_ item: FileSystemItem, to destination: FileSystemItem) -> Bool {
        return move(item, to: destination, withNewName: nil)
    }

    /// 항목 이동 (새 이름 지정 가능)
    @discardableResult
    func move(_ item: FileSystemItem, to destination: FileSystemItem, withNewName newName: String?) -> Bool {
        guard destination.isDirectory else { return false }

        let targetName = newName ?? item.name
        let newURL = destination.url.appendingPathComponent(targetName)

        // 같은 위치로 이동하는 경우 무시
        if newURL == item.url { return false }

        do {
            try DocumentFileStore.validateName(targetName)
            guard !DocumentFileStore.contains(destination.url, in: item.url) else { throw DocumentFileStore.Failure.invalidName }
            try files.move(from: item.url, to: newURL)
            if item.isDirectory { relocateFolderAppearance(from: item.url, to: newURL) }

            // 이전 부모에서 제거
            if let oldParent = item.parent {
                oldParent.children?.removeAll { $0.id == item.id }
                decrementChildCount(for: item, in: oldParent)
            }

            // 새 부모에 추가 (새로고침으로 처리)
            loadChildren(of: destination)

            return true
        } catch {
            operationError = error.localizedDescription
            return false
        }
    }

    // MARK: - 복사

    /// 항목 복사
    @discardableResult
    func copy(_ item: FileSystemItem, to destination: FileSystemItem) -> Bool {
        guard destination.isDirectory else { return false }

        var newURL = destination.url.appendingPathComponent(item.name)

        // 이름 충돌 처리
        var counter = 1
        while FileManager.default.fileExists(atPath: newURL.path) {
            let baseName = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            newURL = destination.url.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try files.copy(from: item.url, to: newURL)
            if item.isDirectory { relocateFolderAppearance(from: item.url, to: newURL, copying: true) }
            loadChildren(of: destination)
            return true
        } catch {
            print("Failed to copy item: \(error)")
            return false
        }
    }

    // MARK: - Finder에서 열기

    // MARK: - 파일 감시

    /// 프로젝트 루트 폴더 감시 시작
    private func startWatching(at url: URL) {
        if let root = projectRoot { watchDirectory(root) }
    }

    private func watchDirectory(_ item: FileSystemItem) {
        let path = item.url.path
        guard directoryWatchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let owner = projectRootURL
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak item] in
            guard let self, let item, self.projectRootURL == owner,
                  self.directoryWatchers[path] != nil, item.url.path == path else { return }
            self.files.events.publish(.init(url: item.url, change: .invalidated))
            self.loadChildren(of: item)
        }
        source.setCancelHandler { close(fd) }
        directoryWatchers[path] = source
        source.resume()
    }

    private func stopWatching() {
        for source in directoryWatchers.values { source.cancel() }
        directoryWatchers.removeAll()
    }

    private func stopWatching(under url: URL) {
        for path in Array(directoryWatchers.keys) where DocumentFileStore.contains(URL(fileURLWithPath: path), in: url) {
            directoryWatchers.removeValue(forKey: path)?.cancel()
        }
    }

    /// 파일 시스템 변경 처리
    private func handleFileSystemChange() {
        // 루트 새로고침
        if let rootItem = projectRoot {
            loadChildren(of: rootItem)
        }
    }

    /// 프로젝트 루트 수동 새로고침
    func refreshProject() {
        guard let rootItem = projectRoot else { return }
        loadChildren(of: rootItem)

        // 펼쳐진 하위 폴더도 새로고침
        refreshExpandedChildren(of: rootItem)
    }

    /// 펼쳐진 자식 폴더 재귀적 새로고침
    private func refreshExpandedChildren(of item: FileSystemItem) {
        guard let children = item.children else { return }

        for child in children where child.isDirectory && child.isExpanded {
            loadChildren(of: child)
            refreshExpandedChildren(of: child)
        }
    }

    /// 모든 폴더의 하위 항목 개수 로드 (재귀적)
    private func loadChildCountsRecursively(of item: FileSystemItem) {
        guard let children = item.children else { return }

        for child in children where child.isDirectory {
            // 아직 자식이 로드되지 않았으면 로드
            if child.children == nil || child.children?.isEmpty == true {
                loadChildren(of: child)
            }
            // 재귀적으로 하위 폴더도 처리
            loadChildCountsRecursively(of: child)
        }
    }

    // MARK: - 유틸리티

    /// 항목의 부모 디렉토리 찾기
    func findParent(of item: FileSystemItem) -> FileSystemItem? {
        // item.parent가 있으면 사용
        if let parent = item.parent {
            return parent
        }

        // 없으면 URL 기반으로 찾기
        let parentURL = item.url.deletingLastPathComponent()
        return findItem(by: parentURL)
    }

    /// URL로 항목 찾기 (재귀 탐색)
    func findItem(by url: URL) -> FileSystemItem? {
        guard let root = projectRoot else { return nil }

        if WorkspaceFileIdentity.same(root.url, url) {
            return root
        }

        return findItemRecursively(in: root, url: url)
    }

    private func findItemRecursively(in parent: FileSystemItem, url: URL) -> FileSystemItem? {
        guard let children = parent.children else { return nil }

        for child in children {
            if WorkspaceFileIdentity.same(child.url, url) {
                return child
            }
            if child.isDirectory, let found = findItemRecursively(in: child, url: url) {
                return found
            }
        }
        return nil
    }

    /// 디렉토리 생성 (없으면)
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                print("Failed to create directory: \(error)")
            }
        }
    }

    /// 폴더가 섹션 폴더인지 확인 (어떤 언어의 섹션 이름이든)
    func sectionType(for item: FileSystemItem) -> ProjectSection? {
        return ProjectSection.from(folderName: item.name)
    }

    /// 항목이 프로젝트 루트의 직접 자식인지 확인
    func isRootChild(_ item: FileSystemItem) -> Bool {
        return item.parent?.url == projectRootURL
    }
}
