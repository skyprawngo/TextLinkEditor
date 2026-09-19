//
//  TabBarView.swift
//  TextlinkEditor
//
//  에디터 탭바 뷰 - EditorTabManager와 연동
//

import SwiftUI

struct TabBarView: View {
    @State private var tabManager = EditorTabManager.shared
    private var fileSystemManager: FileSystemManager { FileSystemManager.shared }

    @State private var draggingTabId: UUID?
    @State private var dragOverTabId: UUID?
    @State private var isDragOverTrailingArea = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                                TabItemView(
                                    title: tab.title,
                                    isModified: tab.isModified,
                                    justSaved: tab.justSaved,
                                    isSelected: tabManager.selectedTabIndex == index,
                                    fileExists: tab.fileExists,
                                    width: TabBarSizing.width(available: max(0, geometry.size.width - 48),
                                        count: tabManager.tabs.count, selected: tabManager.selectedTabIndex == index),
                                    isDragging: draggingTabId == tab.id,
                                    isDragOver: dragOverTabId == tab.id,
                                    onSelect: {
                                        EditorFocusCoordinator.claimEditor(in: NSApp.keyWindow)
                                        tabManager.selectTab(at: index)
                                    },
                                    onClose: { tabManager.closeTab(at: index) },
                                    onRename: { name in
                                        guard let current = tabManager.tabs.first(where: { $0.id == tab.id }), current.fileExists else { return false }
                                        if name == current.title { return true }
                                        let item = fileSystemManager.findItem(by: current.url)
                                            ?? FileSystemItem(url: current.url, isDirectory: false)
                                        let renamed = fileSystemManager.rename(item, to: name)
                                        if renamed { fileSystemManager.refreshProject() }
                                        return renamed
                                    }
                                )
                                .id(tab.id)
                                .onDrag {
                                    draggingTabId = tab.id
                                    return NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(tabId: tab.id, tabIndex: index,
                                    tabManager: tabManager, draggingTabId: $draggingTabId, dragOverTabId: $dragOverTabId))
                            }
                            Button(action: showNewFileDialog) {
                                Image(systemName: "plus").frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.get("explorer.newFile"))
                            .accessibilityLabel(L10n.get("explorer.newFile"))
                            Color.clear.frame(width: 8, height: 28)
                                .contentShape(Rectangle())
                                .onDrop(of: [.text], delegate: TrailingDropDelegate(tabManager: tabManager,
                                    draggingTabId: $draggingTabId, dragOverTabId: $dragOverTabId,
                                    isDragOverTrailingArea: $isDragOverTrailingArea))
                        }
                    }
                    .onChange(of: tabManager.selectedTab?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        if let id = tabManager.selectedTab?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = tabManager.selectedTab?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }

            }
            .frame(height: geometry.size.height, alignment: .center)
        }
        .frame(height: 36)
        .background(TabContextMenuRegion(priority: 0, actions: [
            .init(title: L10n.get("explorer.newFile"), enabled: fileSystemManager.targetDirectoryForNewFile != nil,
                  actionID: ShortcutAction.newFile.rawValue, perform: showNewFileDialog)
        ]))
        .animation(.smooth(duration: 0.24), value: tabManager.selectedTabIndex)
    }

    private func showNewFileDialog() {
        guard let targetDirectory = fileSystemManager.targetDirectoryForNewFile else { return }
        fileSystemManager.showNewFileDialog(in: targetDirectory) { newFileItem in
            // 새 파일이 생성되면 탭으로 열기
            if let fileItem = newFileItem {
                tabManager.openFile(fileItem)
            }
        }
    }
}

struct TabItemView: View {
    let title: String
    let isModified: Bool
    let justSaved: Bool
    let isSelected: Bool
    let fileExists: Bool
    var width: CGFloat = 180
    var isDragging: Bool = false
    var isDragOver: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onRename: (String) -> Bool = { _ in false }
    @State private var isRenaming = false

    @State private var isHovering = false
    @State private var isCloseButtonHovering = false
    /// 저장 완료 점 표시 여부 (애니메이션용)
    @State private var showSavedIndicator = false

    /// 탭 배경색 (선택되지 않은 탭용)
    private var tabBackgroundColor: Color {
        if isHovering {
            return AppColors.tabHoverBackground
        } else {
            return AppColors.tabInactiveBackground
        }
    }

    /// 탭 테두리 색상
    private var tabBorderColor: Color {
        if isSelected {
            return AppColors.tabActiveBorder
        } else {
            return AppColors.tabInactiveBorder
        }
    }

    /// 상태 표시 점 색상
    private var indicatorColor: Color {
        if showSavedIndicator {
            return AppColors.savedIndicator
        } else if isModified {
            return AppColors.modifiedIndicator
        } else {
            return .clear
        }
    }

    /// 상태 표시 점 표시 여부
    private var showIndicator: Bool {
        (isModified || showSavedIndicator) && !isHovering
    }

    var body: some View {
        HStack(spacing: 6) {
            // 닫기 버튼 / 수정 상태 표시 (같은 위치)
            ZStack {
                // 수정/저장 상태 점 (마우스오버가 아닐 때만 표시)
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .opacity(showIndicator ? 1 : 0)
                    .scaleEffect(showIndicator ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.2), value: showIndicator)
                    .animation(.easeInOut(duration: 0.15), value: indicatorColor)

                // 닫기 버튼 (마우스오버 시에만 표시)
                if isHovering {
                    Button(action: onClose) {
                        ZStack {
                            Circle()
                                .fill(isCloseButtonHovering ? AppColors.tabCloseHoverBackground : Color.clear)
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isCloseButtonHovering ? AppColors.toolbarIconActive : AppColors.toolbarIcon)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { isCloseButtonHovering = $0 }
                    .help(L10n.tabs.close)
                }
            }
            .frame(width: 14, height: 14)

            if isRenaming {
                TabNameEditor(title: title, onCommit: { name in
                    if onRename(name) { isRenaming = false; return true }
                    return false
                }, onCancel: { isRenaming = false })
                .frame(maxWidth: .infinity)
                .frame(height: 14)
            } else {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .strikethrough(!fileExists, color: .secondary)
                    .foregroundStyle(fileExists ? AppColors.tabText : .secondary)
            }
        }
        .frame(width: max(30, width - 26))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isSelected ? Color.clear : tabBackgroundColor)
        )
        .glassEffect(isSelected ? .regular : .clear, in: .capsule)
        .contentShape(Capsule())
        // 드래그 중 시각적 피드백
        .opacity(isDragging ? 0.4 : 1.0)
        .scaleEffect(isDragging ? 0.95 : 1.0)
        // 드롭 위치 표시 인디케이터 (글로우 효과)
        .overlay(alignment: .leading) {
            if isDragOver {
                Capsule()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .animation(.easeOut(duration: 0.15), value: isDragOver)
        .accessibilityElement(children: .contain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text(L10n.tabs.close)) { onClose() }
        .onTapGesture { if !isRenaming { onSelect() } }
        .background(TabContextMenuRegion(priority: 1, actions: [
            .init(title: L10n.get("explorer.rename"), enabled: fileExists, perform: { isRenaming = true }),
            .init(title: L10n.tabs.close, actionID: ShortcutAction.closeTab.rawValue, perform: onClose)
        ]))
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: justSaved) { _, newValue in
            if newValue {
                // 저장됨 표시 시작
                withAnimation(.easeOut(duration: 0.15)) {
                    showSavedIndicator = true
                }
            } else {
                // 저장됨 표시 해제 (페이드아웃)
                withAnimation(.easeOut(duration: 0.3)) {
                    showSavedIndicator = false
                }
            }
        }
    }
}

/// Toolbar customization consumes secondary clicks before SwiftUI contextMenu.
/// Route only clicks inside visible tab regions; leave all other window events alone.
private struct TabContextMenuRegion: NSViewRepresentable {
    struct Action {
        let title: String
        var enabled = true
        var actionID: String?
        let perform: () -> Void
    }
    let priority: Int
    let actions: [Action]
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) {
        view.priority = priority
        view.actions = actions
    }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.unregister() }

    final class RegionView: NSView {
        private static let regions = NSHashTable<RegionView>.weakObjects()
        private static var monitor: Any?
        var priority = 0
        var actions: [Action] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unregister()
            guard window != nil else { return }
            Self.regions.add(self)
            if Self.monitor == nil {
                Self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                    guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
                    let region = Self.regions.allObjects.filter {
                        $0.window === event.window && !$0.isHiddenOrHasHiddenAncestor &&
                        $0.visibleRect.intersection($0.bounds).contains($0.convert(event.locationInWindow, from: nil))
                    }.max { $0.priority < $1.priority }
                    guard let region else { return event }
                    let menu = NSMenu()
                    menu.autoenablesItems = false
                    for (index, action) in region.actions.enumerated() {
                        let item = NSMenuItem(title: action.title, action: #selector(RegionView.invoke(_:)), keyEquivalent: "")
                        if let actionID = action.actionID,
                           let binding = KeyboardShortcutManager.shared.binding(for: ShortcutAction(rawValue: actionID)),
                           let keyEquivalent = binding.menuKeyEquivalent {
                            item.keyEquivalent = keyEquivalent
                            item.keyEquivalentModifierMask = binding.modifiers.appKitModifierFlags
                        }
                        item.target = region
                        item.tag = index
                        item.isEnabled = action.enabled
                        menu.addItem(item)
                    }
                    NSMenu.popUpContextMenu(menu, with: event, for: region)
                    return nil
                }
            }
        }
        func unregister() {
            Self.regions.remove(self)
            if Self.regions.allObjects.isEmpty, let monitor = Self.monitor {
                NSEvent.removeMonitor(monitor)
                Self.monitor = nil
            }
        }
        @objc private func invoke(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag), actions[item.tag].enabled else { return }
            actions[item.tag].perform()
        }
    }
}

/// A native field keeps IME, Return/Escape and focus handling inside the tab.
private struct TabNameEditor: NSViewRepresentable {
    let title: String
    let onCommit: (String) -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: title)
        field.font = .systemFont(ofSize: 12)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.setAccessibilityLabel(L10n.get("explorer.rename"))
        context.coordinator.field = field
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let field = coordinator.field, !coordinator.finished else { return event }
            if event.window !== field.window || !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                coordinator.commit()
            }
            return event
        }
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            // Keep the extension visible while selecting the basename for replacement.
            let basename = (title as NSString).deletingPathExtension
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: basename.utf16.count))
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.finished = true
        field.delegate = nil
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabNameEditor
        weak var field: NSTextField?
        var monitor: Any?
        var finished = false
        init(_ parent: TabNameEditor) { self.parent = parent }
        func commit() {
            guard !finished, let field else { return }
            // End IME composition before reading the committed field value.
            (field.currentEditor() as? NSTextView)?.unmarkText()
            let name = field.currentEditor()?.string ?? field.stringValue
            finished = true
            if !parent.onCommit(name) { finished = false }
        }
        func controlTextDidEndEditing(_ notification: Notification) { commit() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let tabId: UUID
    let tabIndex: Int
    let tabManager: EditorTabManager
    @Binding var draggingTabId: UUID?
    @Binding var dragOverTabId: UUID?

    func dropEntered(info: DropInfo) {
        guard draggingTabId != tabId else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            dragOverTabId = tabId
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) {
            dragOverTabId = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingId = draggingTabId else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingId }) else { return false }

        let destinationIndex = tabIndex

        // 탭 이동 즉시 처리 (애니메이션은 TabBarView의 .animation 모디파이어에서 처리)
        if sourceIndex != destinationIndex {
            tabManager.moveTab(from: sourceIndex, to: destinationIndex)
        }

        // 드래그 상태 초기화
        draggingTabId = nil
        dragOverTabId = nil

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return draggingTabId != nil && draggingTabId != tabId
    }
}

// MARK: - Trailing Drop Delegate (마지막 위치로 탭 이동)

struct TrailingDropDelegate: DropDelegate {
    let tabManager: EditorTabManager
    @Binding var draggingTabId: UUID?
    @Binding var dragOverTabId: UUID?
    @Binding var isDragOverTrailingArea: Bool

    func dropEntered(info: DropInfo) {
        guard draggingTabId != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            isDragOverTrailingArea = true
            dragOverTabId = nil
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.15)) {
            isDragOverTrailingArea = false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingId = draggingTabId else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingId }) else { return false }

        let lastIndex = tabManager.tabs.count - 1

        // 이미 마지막이 아니면 마지막으로 이동
        if sourceIndex != lastIndex {
            tabManager.moveTab(from: sourceIndex, to: lastIndex)
        }

        // 드래그 상태 초기화
        draggingTabId = nil
        dragOverTabId = nil
        isDragOverTrailingArea = false

        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return draggingTabId != nil
    }
}

#Preview {
    TabBarView()
}

/// Compress inactive tabs first; retain a readable minimum, then allow horizontal overflow.
enum TabBarSizing {
    static func width(available: CGFloat, count: Int, selected: Bool) -> CGFloat {
        guard count > 1 else { return min(220, max(96, available)) }
        let shared = max(0, available - CGFloat(count - 1) * 4) / (CGFloat(count) + 0.4)
        let inactive = min(160, max(64, min(shared, (available - CGFloat(count - 1) * 4 - 96) / CGFloat(count - 1))))
        return selected ? min(220, max(96, inactive * 1.4)) : inactive
    }
}
