//
//  SettingsView.swift
//  TextlinkEditor
//
//  MainEditorView와 동일한 NavigationSplitView 구조 사용
//

import SwiftUI

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case editor
    case typography
    case ai
    case shortcuts
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.get("settings.general")
        case .typography: return L10n.get("settings.typography")
        case .editor: return L10n.sidebar.editor
        case .ai: return L10n.get("settings.ai")
        case .shortcuts: return L10n.get("settings.shortcuts")
        case .developer: return L10n.get("settings.developer")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .typography: return "textformat"
        case .editor: return "doc.text"
        case .ai: return "sparkles"
        case .shortcuts: return "keyboard"
        case .developer: return "hammer"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settings.selectedTab") private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(200)
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case .general:
                GeneralSettingsView()
            case .ai:
                AISettingsView()
            case .typography:
                TypographySettingsView()
            case .editor:
                EditorSettingsView()
            case .shortcuts:
                ShortcutsSettingsView()
            case .developer:
                DeveloperSettingsView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 600, minHeight: 400)
        .background(ThemeAwareBackground(material: .contentBackground, blendingMode: .behindWindow))
    }
}

#Preview("앱 설정") {
    SettingsView()
}
