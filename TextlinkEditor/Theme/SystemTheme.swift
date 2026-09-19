//
//  SystemTheme.swift
//  TextlinkEditor
//
//  시스템 테마 팔레트
//  macOS 시스템 설정(라이트/다크)을 따르는 테마
//  포커스 상태와 무관하게 일관된 색상 유지
//

import SwiftUI
import AppKit

/// 시스템 테마
/// macOS 시스템 설정(라이트/다크)을 따름
/// 포커스 상태와 무관하게 일관된 밝기 유지
enum SystemTheme: ThemePalette, ThemePaletteNSColor {

    // MARK: - Theme Metadata

    static let id = "system"
    static let displayNameKey = "settings.theme.system"
    static let isOpaque = false

    // MARK: - Helper

    /// 현재 시스템이 다크 모드인지 확인
    private static var isDarkMode: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Background

    static var background: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var barBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var sidebarBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var contentBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var textEditorBackground: Color {
        Color(nsColor: nsTextEditorBackground)
    }

    static var controlBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    // MARK: - Text
    // 포커스 상태와 무관하게 항상 일관된 밝기 유지

    static var textPrimary: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.85)
    }

    static var textSecondary: Color {
        isDarkMode ? Color.white.opacity(0.55) : Color.black.opacity(0.55)
    }

    static var textTertiary: Color {
        isDarkMode ? Color.white.opacity(0.35) : Color.black.opacity(0.35)
    }

    static var textDisabled: Color {
        isDarkMode ? Color.white.opacity(0.25) : Color.black.opacity(0.25)
    }

    // MARK: - Tab Bar

    static var tabInactiveBackground: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    static var tabHoverBackground: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

    static var tabDefaultBackground: Color {
        Color.clear
    }

    static var tabActiveBorder: Color {
        Color(nsColor: .separatorColor)
    }

    static var tabInactiveBorder: Color {
        Color(nsColor: .separatorColor).opacity(0.3)
    }

    static var tabText: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.85)
    }

    static var tabCloseHoverBackground: Color {
        Color(nsColor: .quaternaryLabelColor)
    }

    static var tabSelectedShadow: Color {
        Color(nsColor: .shadowColor).opacity(0.3)
    }

    // MARK: - Toolbar

    static var toolbarButtonHover: Color {
        Color(nsColor: .controlAccentColor).opacity(0.1)
    }

    static var toolbarButtonPressed: Color {
        Color(nsColor: .controlAccentColor).opacity(0.2)
    }

    static var toolbarToggleSelected: Color {
        Color(nsColor: .controlAccentColor).opacity(0.15)
    }

    /// 툴바 아이콘 색상 - 포커스 상태와 무관하게 항상 밝은/어두운 색상 유지
    static var toolbarIcon: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.85)
    }

    /// 툴바 아이콘 활성 색상 - 포커스 상태와 무관하게 항상 밝은/어두운 색상 유지
    static var toolbarIconActive: Color {
        isDarkMode ? Color.white : Color.black
    }

    // MARK: - Sidebar

    static var sidebarItemSelected: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    static var sidebarItemHover: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

    static var sidebarHeaderText: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.85)
    }

    // MARK: - Separators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static var separatorOpaque: Color {
        Color(nsColor: .gridColor)
    }

    static var controlBorder: Color {
        Color(nsColor: .separatorColor)
    }

    // MARK: - Selection

    static var selectionEmphasized: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    static var selectionUnemphasized: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    // MARK: - Editor

    static var currentLineBackground: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

    static var lineNumber: Color {
        Color(nsColor: .tertiaryLabelColor)
    }

    // MARK: - Accent & Focus

    static var accent: Color {
        Color(nsColor: .controlAccentColor)
    }

    static var focusRing: Color {
        Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.5)
    }

    // MARK: - Indicators

    static var modifiedIndicator: Color {
        Color(nsColor: .systemOrange)
    }

    static var savedIndicator: Color {
        Color(nsColor: .systemGreen)
    }

    static var errorIndicator: Color {
        Color(nsColor: .systemRed)
    }

    static var warningIndicator: Color {
        Color(nsColor: .systemYellow)
    }

    // MARK: - Shadows

    static var shadowDrop: Color {
        Color(nsColor: .shadowColor).opacity(0.2)
    }

    // MARK: - Buttons

    static var addButtonIcon: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.85)
    }

    static var addButtonHover: Color {
        Color(nsColor: .controlAccentColor).opacity(0.1)
    }

    static var addButtonPressed: Color {
        Color(nsColor: .controlAccentColor).opacity(0.2)
    }

    // MARK: - NSColor (AppKit용)

    static var nsEditorText: NSColor {
        .labelColor
    }

    static var nsMarkdownSyntax: NSColor {
        .tertiaryLabelColor
    }

    static var nsEditorBackground: NSColor {
        .textBackgroundColor
    }

    static var nsTextEditorBackground: NSColor {
        isDarkMode ? DarkTheme.nsTextEditorBackground : LightTheme.nsTextEditorBackground
    }

    static var nsCurrentLineHighlight: NSColor {
        NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
    }

    static var nsEditorCursor: NSColor {
        .labelColor
    }
}
