//
//  ProjectExplorerView.swift
//  TextlinkEditor
//
//  프로젝트 탐색기 뷰 (파인더 스타일)
//  - SidebarView 통합
//  - 플랫 리스트 기반 렌더링 (재귀 없음)
//

import SwiftUI

/// 플랫 리스트용 항목 데이터 (depth, treeLines 포함)
struct FlatFileItem: Identifiable {
    let id: UUID
    let item: FileSystemItem
    let depth: Int
    let parentTreeLines: [Bool]

    init(item: FileSystemItem, depth: Int, parentTreeLines: [Bool]) {
        self.id = item.id
        self.item = item
        self.depth = depth
        self.parentTreeLines = parentTreeLines
    }
}

struct ProjectExplorerView: View {
    @Environment(\.openWindow) private var openWindow

    private var fileSystemManager: FileSystemManager { FileSystemManager.shared }
    private var projectManager: ProjectManager { ProjectManager.shared }
    @State private var tabManager = EditorTabManager.shared

    /// 선택된 항목들 (다중 선택 지원)
    @State private var selectedItemIds: Set<UUID> = []
    /// 마지막으로 단일 선택된 항목 ID (Shift 범위 선택의 기준점)
    @State private var lastSelectedItemId: UUID?
    @State private var isRefreshing: Bool = false
    @AppStorage(SidebarAppearance.textSizeKey, store: SidebarAppearance.store) private var storedTextSize = SidebarAppearance.defaultTextSize
    @AppStorage(SidebarAppearance.iconSizeKey, store: SidebarAppearance.store) private var storedIconSize = SidebarAppearance.defaultIconSize

    /// 캐시된 플랫 리스트 (렌더링 + Shift 범위 선택용)
    @State private var flatList: [FlatFileItem] = []
    /// 캐시된 URL → Item 매핑 (드래그 앤 드롭용)
    @State private var itemByURL: [URL: FileSystemItem] = [:]

    /// NSEvent 키 모니터
    @State private var keyMonitor: Any?
    /// 뷰가 호버 중인지 여부 (키 이벤트 처리 조건)
    @State private var isViewHovered: Bool = false

    /// EditorView에서 현재 편집 중인 내용을 가져오기 위한 콜백
    var getCurrentEditorContent: (() -> String?)?
    var git: ProjectGitModel?
    var collaboration: CollaborationCoordinator?
    private var textSize: Double { SidebarAppearance.bounded(storedTextSize, in: SidebarAppearance.textSizeRange, fallback: SidebarAppearance.defaultTextSize) }
    private var iconSize: Double { SidebarAppearance.bounded(storedIconSize, in: SidebarAppearance.iconSizeRange, fallback: SidebarAppearance.defaultIconSize) }

    var body: some View {
        VStack(spacing: 0) {
            // 프로젝트 탐색기 메인 콘텐츠
            VStack(alignment: .leading, spacing: 0) {
                explorerHeader

                Divider()

                // 파일 트리 (플랫 리스트 기반)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if fileSystemManager.projectRoot != nil {
                            if !flatList.isEmpty {
                                ForEach(flatList) { flatItem in
                                    FileSystemItemRow(
                                        item: flatItem.item,
                                        depth: flatItem.depth,
                                        onSelect: handleSelection,
                                        onMoveItem: { handleMoveItem($0, to: $1) },
                                        onCacheUpdate: updateCache,
                                        onItemDeleted: { closeTabsForDeletedItems([$0]) },
                                        isItemSelected: { selectedItemIds.contains($0) },
                                        findItemByURL: { itemByURL[$0] },
                                        parentTreeLines: flatItem.parentTreeLines
                                    )
                                }
                            } else {
                                emptyStateView
                            }
                        } else {
                            noProjectView
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
                // Rows accept drops only when the pointer is over a folder. A drop over
                // any other part of the explorer belongs to the project root.
                .onDrop(of: SidebarFileDrop.types, isTargeted: nil) { providers in
                    guard let rootItem = fileSystemManager.projectRoot else { return false }
                    return SidebarFileDrop.accept(providers, destination: rootItem, manager: fileSystemManager,
                        find: { itemByURL[$0] }, move: { handleMoveItem($0, to: rootItem) }, completion: updateCache)
                }
            }
            .contextMenu { rootContextMenu }
            .frame(maxHeight: .infinity)

            // 설정 버튼 (하단)
            if let git, let collaboration { ProjectGitSidebar(model: git, collaboration: collaboration) }
            settingsFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(projectManager.currentProject?.name ?? "")
        .onHover { hovering in
            isViewHovered = hovering
        }
        .onChange(of: fileSystemManager.revision) { _, _ in updateCache() }
        .onChange(of: fileSystemManager.projectRoot?.id) { _, _ in
            updateCache()
        }
        .onAppear {
            updateCache()
            setupKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - Header

    private var explorerHeader: some View {
        HStack {
            Text(projectManager.currentProject?.name ?? L10n.sidebar.project)
                .font(.system(size: max(10, textSize - 1), weight: .semibold))
                .foregroundStyle(AppColors.sidebarHeaderText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(projectManager.currentProject?.name ?? L10n.sidebar.project)

            Spacer()

            // 새 파일 버튼
            Button(action: { showNewFileDialog() }) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: iconSize))
                    .foregroundStyle(AppColors.toolbarIcon)
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .help(L10n.get("explorer.newFile"))
            .accessibilityLabel(L10n.get("explorer.newFile"))
            .disabled(fileSystemManager.projectRoot == nil)

            // 새 폴더 버튼
            Button(action: { showNewFolderDialog() }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: iconSize))
                    .foregroundStyle(AppColors.toolbarIcon)
                    .frame(width: 24, height: 26)
            }
            .buttonStyle(.plain)
            .help(L10n.get("explorer.newFolder"))
            .accessibilityLabel(L10n.get("explorer.newFolder"))
            .disabled(fileSystemManager.projectRoot == nil)

            // 새로고침 버튼
            Button(action: { refresh() }) {
                if isRefreshing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: iconSize))
                        .foregroundStyle(AppColors.toolbarIcon)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 26)
            .help(L10n.get("explorer.refresh"))
            .accessibilityLabel(L10n.get("explorer.refresh"))
            .disabled(isRefreshing || fileSystemManager.projectRoot == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Settings Footer (SidebarView에서 통합)

    private var settingsFooter: some View {
        HStack {
            Spacer()
            Button(action: { openWindow(id: "settings") }) {
                Image(systemName: "gearshape")
                    .font(.system(size: iconSize))
                    .foregroundStyle(AppColors.toolbarIcon)
            }
            .buttonStyle(.plain)
            .help(L10n.sidebar.settings)
            .accessibilityLabel(L10n.sidebar.settings)
            .padding(8)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: iconSize + 11))
                .foregroundStyle(AppColors.toolbarIcon)

            Text(L10n.get("explorer.emptyFolder"))
                .font(.system(size: max(10, textSize - 1)))
                .foregroundStyle(AppColors.textTertiary)

            Button(action: { showNewFileDialog() }) {
                Text(L10n.get("explorer.createFirstFile"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var noProjectView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.toolbarIcon)

            Text(L10n.get("explorer.noProject"))
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Root Context Menu

    @ViewBuilder
    private var rootContextMenu: some View {
        if fileSystemManager.projectRoot != nil {
            Button(action: { showNewFileDialog() }) {
                Label(L10n.get("explorer.newFile"), systemImage: "doc.badge.plus")
            }

            Button(action: { showNewFolderDialog() }) {
                Label(L10n.get("explorer.newFolder"), systemImage: "folder.badge.plus")
            }

            Divider()

            Button(action: { refresh() }) {
                Label(L10n.get("explorer.refresh"), systemImage: "arrow.clockwise")
            }

            if let rootItem = fileSystemManager.projectRoot {
                Button(action: { fileSystemManager.revealInFinder(rootItem) }) {
                    Label(L10n.get("explorer.revealInFinder"), systemImage: "folder")
                }
            }
        }
    }

    // MARK: - Key Monitor

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.modifierFlags.contains(.command) && event.keyCode == 51 {
                if !selectedItemIds.isEmpty && isViewHovered {
                    DispatchQueue.main.async {
                        deleteSelectedItems()
                    }
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Actions

    private func refresh() {
        isRefreshing = true
        fileSystemManager.refreshProject()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isRefreshing = false
            updateCache()
        }
    }

    private func showNewFileDialog() {
        guard let rootItem = fileSystemManager.projectRoot else { return }
        fileSystemManager.showNewFileDialog(in: rootItem) { newItem in
            if newItem != nil {
                updateCache()
            }
        }
    }

    private func showNewFolderDialog() {
        guard let rootItem = fileSystemManager.projectRoot else { return }
        fileSystemManager.showNewFolderDialog(in: rootItem) { newItem in
            if newItem != nil {
                updateCache()
            }
        }
    }

    /// 선택 처리 (Shift/Command 키 지원)
    private func handleSelection(_ item: FileSystemItem, modifiers: EventModifiers) {
        if modifiers.contains(.shift), let lastId = lastSelectedItemId {
            // Shift+클릭: 범위 선택
            if let startIndex = flatList.firstIndex(where: { $0.id == lastId }),
               let endIndex = flatList.firstIndex(where: { $0.id == item.id }) {
                let range = startIndex <= endIndex ? startIndex...endIndex : endIndex...startIndex
                let rangeIds = Set(flatList[range].map { $0.id })
                selectedItemIds = rangeIds
            }
        } else if modifiers.contains(.command) {
            // Command+클릭: 토글 선택
            if selectedItemIds.contains(item.id) {
                selectedItemIds.remove(item.id)
                if lastSelectedItemId == item.id {
                    lastSelectedItemId = selectedItemIds.first
                }
            } else {
                selectedItemIds.insert(item.id)
                lastSelectedItemId = item.id
            }
        } else {
            // 일반 클릭: 단일 선택
            selectedItemIds = [item.id]
            lastSelectedItemId = item.id
            fileSystemManager.selectedItem = item
            if !item.isDirectory {
                tabManager.openFile(item)
            }
        }
    }

    // MARK: - Cache Management

    /// 플랫 리스트 캐시 갱신
    private func updateCache() {
        guard let rootItem = fileSystemManager.projectRoot,
              let children = rootItem.children else {
            flatList = []
            itemByURL = [:]
            return
        }

        var newFlatList: [FlatFileItem] = []
        var urlMap: [URL: FileSystemItem] = [:]

        for (index, child) in children.enumerated() {
            let isLastChild = index == children.count - 1
            appendItemsRecursively(
                child,
                depth: 0,
                parentTreeLines: [],
                isLastInParent: isLastChild,
                to: &newFlatList,
                urlMap: &urlMap
            )
        }

        flatList = newFlatList
        itemByURL = urlMap
    }

    /// 재귀적으로 플랫 리스트에 항목 추가
    private func appendItemsRecursively(
        _ item: FileSystemItem,
        depth: Int,
        parentTreeLines: [Bool],
        isLastInParent: Bool,
        to list: inout [FlatFileItem],
        urlMap: inout [URL: FileSystemItem]
    ) {
        // 현재 depth의 세로선 표시 여부: 마지막 자식이 아니면 세로선 유지
        let currentTreeLines = parentTreeLines + [!isLastInParent]

        let flatItem = FlatFileItem(
            item: item,
            depth: depth,
            parentTreeLines: currentTreeLines
        )
        list.append(flatItem)
        urlMap[item.url] = item

        // 펼쳐진 폴더의 자식들 추가
        if item.isDirectory && item.isExpanded, let children = item.children {
            for (index, child) in children.enumerated() {
                let isLast = index == children.count - 1
                appendItemsRecursively(
                    child,
                    depth: depth + 1,
                    parentTreeLines: currentTreeLines,
                    isLastInParent: isLast,
                    to: &list,
                    urlMap: &urlMap
                )
            }
        }
    }

    /// ID로 FileSystemItem 찾기
    private func findItem(by id: UUID) -> FileSystemItem? {
        flatList.first { $0.id == id }?.item
    }

    /// 선택된 항목 삭제 (Cmd+Backspace)
    private func deleteSelectedItems() {
        guard !selectedItemIds.isEmpty else { return }

        let itemsToDelete = selectedItemIds.compactMap { findItem(by: $0) }
        guard !itemsToDelete.isEmpty else { return }

        if itemsToDelete.count == 1, let item = itemsToDelete.first {
            fileSystemManager.showDeleteConfirmation(for: item) { deleted in
                if deleted {
                    selectedItemIds.removeAll()
                    lastSelectedItemId = nil
                    updateCache() // 삭제 후 캐시 갱신
                    closeTabsForDeletedItems([item]) // 탭바 업데이트
                }
            }
        } else {
            fileSystemManager.showMultipleDeleteConfirmation(for: itemsToDelete) { deleted in
                if deleted {
                    selectedItemIds.removeAll()
                    lastSelectedItemId = nil
                    updateCache() // 삭제 후 캐시 갱신
                    closeTabsForDeletedItems(itemsToDelete) // 탭바 업데이트
                }
            }
        }
    }

    /// 삭제된 항목에 해당하는 탭 닫기
    private func closeTabsForDeletedItems(_ items: [FileSystemItem]) {
        for item in items {
            if item.isDirectory {
                // 폴더인 경우: 해당 폴더 하위의 모든 파일 탭 닫기
                tabManager.closeTabsUnder(folderURL: item.url)
            } else {
                // 파일인 경우: 해당 파일 탭 닫기
                if let tabIndex = tabManager.findTab(with: item.url) {
                    tabManager.closeTab(at: tabIndex, force: true)
                }
            }
        }
    }

    // MARK: - Drag and Drop

    @discardableResult
    private func handleMoveItem(_ sourceItem: FileSystemItem, to destinationFolder: FileSystemItem) -> Bool {
        // A same-directory drop has no filesystem work to perform. Reject it before
        // collision handling so the item's own name never produces a rename alert.
        guard !WorkspaceFileIdentity.same(sourceItem.url.deletingLastPathComponent(), destinationFolder.url) else {
            return false
        }

        if !sourceItem.isDirectory && tabManager.isModified(url: sourceItem.url) {
            fileSystemManager.showModifiedFileMoveDialog(fileName: sourceItem.name) { result in
                switch result {
                case .saveAndMove:
                    tabManager.flushEditor()
                    guard let content = tabManager.getCachedContent(for: sourceItem.url),
                          let index = tabManager.findTab(with: sourceItem.url),
                          tabManager.saveTab(at: index, content: content) else {
                        tabManager.showSaveError(for: sourceItem.url)
                        return
                    }
                    self.checkNameConflictAndMove(sourceItem, to: destinationFolder)
                case .cancel:
                    break
                }
            }
        } else {
            checkNameConflictAndMove(sourceItem, to: destinationFolder)
        }
        return true
    }

    private func checkNameConflictAndMove(_ sourceItem: FileSystemItem, to destinationFolder: FileSystemItem) {
        if fileSystemManager.fileExists(named: sourceItem.name, in: destinationFolder) {
            fileSystemManager.showNameConflictDialog(fileName: sourceItem.name) { result in
                switch result {
                case .rename(let newName):
                    if fileSystemManager.fileExists(named: newName, in: destinationFolder) {
                        self.checkNameConflictAndMove(sourceItem, to: destinationFolder)
                    } else {
                        if fileSystemManager.move(sourceItem, to: destinationFolder, withNewName: newName) {
                            updateCache()
                        }
                    }
                case .cancel:
                    break
                }
            }
        } else {
            if fileSystemManager.move(sourceItem, to: destinationFolder) {
                updateCache()
            }
        }
    }
}

#Preview("빈 상태") {
    ProjectExplorerView()
        .frame(width: 220, height: 400)
}

#Preview("모의 데이터") {
    let root = FileSystemItem(
        url: URL(fileURLWithPath: "/tmp/MyNovel.weaveproj"),
        isDirectory: true
    )
    root.isExpanded = true

    let sections = [
        ("원고", true, 3),
        ("설정", true, 5),
        ("플롯", true, 2),
        ("인물", true, 0),
        ("장면", true, 1),
        ("자료", true, 4)
    ]

    var sectionItems: [FileSystemItem] = []
    for (name, isDir, childCount) in sections {
        let item = FileSystemItem(
            url: URL(fileURLWithPath: "/tmp/MyNovel.weaveproj/\(name)"),
            isDirectory: isDir,
            parent: root
        )
        if childCount > 0 {
            item.children = (1...childCount).map { index in
                FileSystemItem(
                    url: URL(fileURLWithPath: "/tmp/MyNovel.weaveproj/\(name)/item\(index).md"),
                    isDirectory: false,
                    parent: item
                )
            }
        }
        sectionItems.append(item)
    }
    root.children = sectionItems
    sectionItems[0].isExpanded = true

    return ProjectExplorerView()
        .frame(width: 220, height: 400)
}
