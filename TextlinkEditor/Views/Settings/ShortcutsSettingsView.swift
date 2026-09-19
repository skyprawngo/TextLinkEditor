import SwiftUI

// MARK: - Shortcuts Settings

/// 단축키 테이블 열 ID
enum ShortcutColumnID: String {
    case action = "action"
    case category = "category"
    case shortcut = "shortcut"
    case toggle = "toggle"
}

struct ShortcutsSettingsView: View {
    @State private var shortcutManager = KeyboardShortcutManager.shared
    @State private var searchText: String = ""
    @State private var selectedCategory: ShortcutCategory? = nil
    @State private var editingBinding: ShortcutBinding? = nil

    // 열 가시성 상태
    @SceneStorage("shortcuts.column.action") private var showActionColumn = true
    @SceneStorage("shortcuts.column.category") private var showCategoryColumn = true
    @SceneStorage("shortcuts.column.shortcut") private var showShortcutColumn = true
    @SceneStorage("shortcuts.column.toggle") private var showToggleColumn = true

    /// 필터링된 바인딩 목록
    private var filteredBindings: [ShortcutBinding] {
        var bindings = shortcutManager.bindings

        // 카테고리 필터
        if let category = selectedCategory {
            bindings = bindings.filter { $0.action.category == category }
        }

        // 검색어 필터
        if !searchText.isEmpty {
            bindings = bindings.filter {
                $0.action.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.displayString.localizedCaseInsensitiveContains(searchText)
            }
        }

        return bindings
    }

    var body: some View {
        VStack(spacing: 0) {
            // 툴바
            shortcutsToolbar

            Divider()

            // 테이블
            shortcutsTable
        }
        .sheet(item: $editingBinding) { binding in
            ShortcutEditSheet(binding: binding) { updatedBinding in
                shortcutManager.updateBinding(updatedBinding)
            }
        }
    }

    // MARK: - Toolbar

    private var shortcutsToolbar: some View {
        HStack(spacing: 12) {
            // 검색
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.toolbarIcon)
                TextField(L10n.get("settings.shortcuts.search"), text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.toolbarIcon)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(AppColors.controlBackground)
            .cornerRadius(6)
            .frame(maxWidth: 200)

            // 카테고리 필터
            Picker("", selection: $selectedCategory) {
                Text(L10n.get("settings.shortcuts.allCategories"))
                    .tag(nil as ShortcutCategory?)

                Divider()

                ForEach(ShortcutCategory.allCases) { category in
                    Text(category.displayName).tag(category as ShortcutCategory?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer()

            // 열 표시/숨기기 메뉴
            Menu {
                Toggle(L10n.get("settings.shortcuts.action"), isOn: $showActionColumn)
                Toggle(L10n.get("settings.shortcuts.category"), isOn: $showCategoryColumn)
                Toggle(L10n.get("settings.shortcuts.shortcut"), isOn: $showShortcutColumn)
                Toggle(L10n.get("settings.shortcuts.toggle"), isOn: $showToggleColumn)

                Divider()

                Button(L10n.get("settings.shortcuts.showAllColumns")) {
                    showActionColumn = true
                    showCategoryColumn = true
                    showShortcutColumn = true
                    showToggleColumn = true
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help(L10n.get("settings.shortcuts.columnVisibility"))

            // 기본값으로 초기화
            Button {
                shortcutManager.resetToDefaults()
            } label: {
                Text(L10n.get("settings.shortcuts.resetAll"))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Table

    private var shortcutsTable: some View {
        Table(filteredBindings) {
            // 액션 이름 열
            if showActionColumn {
                TableColumn(L10n.get("settings.shortcuts.action")) { binding in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(binding.isEnabled ? AppColors.savedIndicator : AppColors.textTertiary)
                            .frame(width: 8, height: 8)

                        Text(binding.action.displayName)
                            .lineLimit(1)
                    }
                    .background(ShortcutTableScrollBoundary())
                }
                .width(min: 100, ideal: 180, max: 300)
            }

            // 카테고리 열
            if showCategoryColumn {
                TableColumn(L10n.get("settings.shortcuts.category")) { binding in
                    Text(binding.action.category.displayName)
                        .lineLimit(1)
                        .foregroundStyle(AppColors.textSecondary)
                        .font(.caption)
                        .background(ShortcutTableScrollBoundary())
                }
                .width(min: 60, ideal: 80, max: 120)
            }

            // 단축키 열
            if showShortcutColumn {
                TableColumn(L10n.get("settings.shortcuts.shortcut")) { binding in
                    Button {
                        editingBinding = binding
                    } label: {
                        Group {
                            if binding.isEnabled {
                                Text(binding.displayString)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppColors.controlBackground)
                                    .cornerRadius(4)
                            } else {
                                Text("-")
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(binding.action.displayName), \(binding.displayString)")
                    .help(L10n.get("settings.shortcuts.editTitle"))
                    .background(ShortcutTableScrollBoundary())
                }
                .width(min: 100, ideal: 160, max: 250)
            }

            // 활성화 토글 열
            if showToggleColumn {
                TableColumn(L10n.get("settings.shortcuts.toggle")) { binding in
                    Toggle("", isOn: Binding(
                        get: { binding.isEnabled },
                        set: { _ in
                            shortcutManager.toggleEnabled(for: binding.action)
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .background(ShortcutTableScrollBoundary())
                }
                .width(min: 70, ideal: 90, max: 130)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

/// Attach inside cells so only this table's enclosing scroll view is configured.
/// Every column participates because users can hide any of the other columns.
private struct ShortcutTableScrollBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ nsView: BoundaryView, context: Context) {
        nsView.configureScrollView()
    }

    final class BoundaryView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollView()
        }

        func configureScrollView() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.verticalScrollElasticity != .none { scroll.verticalScrollElasticity = .none }
            // SwiftUI estimates offscreen rows at 24pt, then measures the shortcut
            // badges/switches taller as they appear. A changing document height
            // makes the scroll position unstable even far from either boundary.
            if let table = scroll.documentView as? NSTableView {
                if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
                if table.rowHeight != 32 { table.rowHeight = 32 }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
