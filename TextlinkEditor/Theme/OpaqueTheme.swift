//
//  OpaqueTheme.swift
//  TextlinkEditor
//
//  불투명 테마 팔레트
//  VisualEffect 배경을 사용하지 않고 고정 색상 사용
//  다크 배경에 파란색 포인트 컬러
//

import SwiftUI
import AppKit

/// 불투명 테마
/// 다크 배경 + 파란색 포인트 컬러, VisualEffect 미사용
enum OpaqueTheme: ThemePalette, ThemePaletteNSColor {

    // MARK: - Theme Metadata

    static let id = "opaque"
    static let displayNameKey = "settings.theme.opaque"
    static let isOpaque = true

    // MARK: - Color Palette (고정 색상)

    /// 배경색 계열
    private static let bgDark = Color(red: 0.08, green: 0.08, blue: 0.10)        // #141419
    private static let bgMedium = Color(red: 0.10, green: 0.10, blue: 0.13)      // #1A1A21
    private static let bgLight = Color(red: 0.14, green: 0.14, blue: 0.18)       // #24242E

    /// 텍스트 색상 계열
    private static let textWhite = Color(red: 0.93, green: 0.93, blue: 0.95)     // #EDEDED
    private static let textGray = Color(red: 0.65, green: 0.65, blue: 0.70)      // #A6A6B3
    private static let textDimmed = Color(red: 0.45, green: 0.45, blue: 0.50)    // #737380
    private static let textDisabledColor = Color(red: 0.35, green: 0.35, blue: 0.40) // #595966

    /// 포인트 컬러 (파란색)
    private static let accentBlue = Color(red: 0.25, green: 0.52, blue: 0.96)    // #4085F5
    private static let accentBlueLight = Color(red: 0.35, green: 0.60, blue: 1.0) // #5999FF
    private static let accentBlueDark = Color(red: 0.18, green: 0.40, blue: 0.80) // #2E66CC

    /// 구분선 색상
    private static let borderColor = Color(red: 0.20, green: 0.20, blue: 0.25)   // #333340
    private static let borderLightColor = Color(red: 0.25, green: 0.25, blue: 0.30) // #40404D

    // MARK: - Background

    static var background: Color { bgDark }
    static var barBackground: Color { bgMedium }
    static var sidebarBackground: Color { bgMedium }
    static var contentBackground: Color { bgDark }
    static var textEditorBackground: Color { Color(nsColor: nsTextEditorBackground) }
    static var controlBackground: Color { bgLight }

    // MARK: - Text

    static var textPrimary: Color { textWhite }
    static var textSecondary: Color { textGray }
    static var textTertiary: Color { textDimmed }
    static var textDisabled: Color { textDisabledColor }

    // MARK: - Tab Bar

    static var tabInactiveBackground: Color { bgLight }
    static var tabHoverBackground: Color { bgLight.opacity(0.5) }
    static var tabDefaultBackground: Color { Color.clear }
    static var tabActiveBorder: Color { borderLightColor }
    static var tabInactiveBorder: Color { borderColor.opacity(0.3) }
    static var tabText: Color { textWhite }
    static var tabCloseHoverBackground: Color { textDimmed.opacity(0.3) }
    static var tabSelectedShadow: Color { Color.black.opacity(0.4) }

    // MARK: - Toolbar

    static var toolbarButtonHover: Color { accentBlue.opacity(0.15) }
    static var toolbarButtonPressed: Color { accentBlue.opacity(0.25) }
    static var toolbarToggleSelected: Color { accentBlue.opacity(0.20) }
    static var toolbarIcon: Color { textWhite }
    static var toolbarIconActive: Color { accentBlueLight }

    // MARK: - Sidebar

    static var sidebarItemSelected: Color { accentBlue }
    static var sidebarItemHover: Color { bgLight.opacity(0.7) }
    static var sidebarHeaderText: Color { textWhite }

    // MARK: - Separators

    static var separator: Color { borderColor }
    static var separatorOpaque: Color { borderLightColor }
    static var controlBorder: Color { borderColor }

    // MARK: - Selection

    static var selectionEmphasized: Color { accentBlue }
    static var selectionUnemphasized: Color { bgLight }

    // MARK: - Editor

    static var currentLineBackground: Color { bgLight.opacity(0.5) }
    static var lineNumber: Color { textTertiary }

    // MARK: - Accent & Focus

    static var accent: Color { accentBlue }
    static var focusRing: Color { accentBlue.opacity(0.5) }

    // MARK: - Indicators

    static var modifiedIndicator: Color { Color(red: 1.0, green: 0.58, blue: 0.0) }   // #FF9500
    static var savedIndicator: Color { Color(red: 0.19, green: 0.82, blue: 0.35) }    // #30D158
    static var errorIndicator: Color { Color(red: 1.0, green: 0.23, blue: 0.19) }     // #FF3B30
    static var warningIndicator: Color { Color(red: 1.0, green: 0.84, blue: 0.04) }   // #FFD60A

    // MARK: - Shadows

    static var shadowDrop: Color { Color.black.opacity(0.3) }

    // MARK: - Buttons

    static var addButtonIcon: Color { textWhite }
    static var addButtonHover: Color { accentBlue.opacity(0.15) }
    static var addButtonPressed: Color { accentBlue.opacity(0.25) }

    // MARK: - NSColor (AppKit용)

    static var nsEditorText: NSColor {
        NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0)
    }

    static var nsMarkdownSyntax: NSColor {
        NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1.0)
    }

    static var nsEditorBackground: NSColor {
        NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    }

    static var nsTextEditorBackground: NSColor {
        NSColor(red: 0.065, green: 0.065, blue: 0.08, alpha: 1.0)
    }

    static var nsCurrentLineHighlight: NSColor {
        NSColor(red: 0.20, green: 0.20, blue: 0.24, alpha: 0.5)
    }

    static var nsEditorCursor: NSColor {
        NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1.0)
    }
}
