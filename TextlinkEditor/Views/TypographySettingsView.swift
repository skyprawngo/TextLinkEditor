import AppKit
import SwiftUI

struct TypographySettingsView: View {
  @State private var category = "editor"
  @State private var appFontName = UserSettings.shared.appFontName
  @AppStorage(SidebarAppearance.textSizeKey, store: SidebarAppearance.store) private
    var sidebarTextSize = SidebarAppearance.defaultTextSize
  @AppStorage(SidebarAppearance.iconSizeKey, store: SidebarAppearance.store) private
    var sidebarIconSize = SidebarAppearance.defaultIconSize
  @AppStorage(EditorToolbarAppearance.iconSizeKey, store: EditorToolbarAppearance.store) private
    var toolbarIconSize = EditorToolbarAppearance.defaultIconSize
  @AppStorage(EditorToolbarAppearance.numberSizeKey, store: EditorToolbarAppearance.store) private
    var toolbarNumberSize = EditorToolbarAppearance.defaultNumberSize
  @AppStorage(EditorToolbarAppearance.heightKey, store: EditorToolbarAppearance.store) private
    var toolbarHeight = EditorToolbarAppearance.defaultHeight
  @State private var fontSize: CGFloat = UserSettings.shared.editorFontSize
  @State private var fontName = UserSettings.shared.editorFontName
  @State private var letterSpacing: Double = Double(UserSettings.shared.editorLetterSpacing)
  @State private var lineSpacing: LineSpacingOption =
    LineSpacingOption(rawValue: UserSettings.shared.editorLineSpacing) ?? .normal
  @AppStorage("panel.fontName") private var panelFontName = ""
  @AppStorage("panel.fontSize") private var panelFontSize = 13.0
  @AppStorage("panel.lineSpacing") private var panelLineSpacing = 3.0
  @AppStorage("panel.letterSpacing") private var panelLetterSpacing = 0.0
  /// 표시용 앱 폰트 이름
  private var displayAppFontName: String {
    appFontName.isEmpty ? L10n.get("settings.font.system") : appFontName
  }

  var body: some View {
    VStack(spacing: 0) {
      LiquidGlassSegmentedControl(
        title: L10n.get("settings.typography"), selection: $category,
        options: ["editor", "sidebar", "toolbar", "panel"],
        label: { L10n.get("settings.typography." + $0) }
      )
        .padding(20)
      Form {
        Section(L10n.get("settings.font.appFont")) {
          // 앱 전역 폰트 설정
          HStack {
            Text(L10n.get("settings.font.appFont"))

            Spacer()

            Button {
              showAppFontPanel()
            } label: {
              HStack(spacing: 4) {
                Text(displayAppFontName)
                  .lineLimit(1)
                  .frame(maxWidth: 120)

                Image(systemName: "chevron.down")
                  .font(.caption)
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(AppColors.controlBackground)
              .cornerRadius(6)
            }
            .buttonStyle(.plain)

            // 시스템 기본으로 리셋 버튼 (커스텀 폰트 선택 시에만 표시)
            if !appFontName.isEmpty {
              Button {
                appFontName = ""
                UserSettings.shared.appFontName = ""
              } label: {
                Image(systemName: "arrow.counterclockwise")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .help(L10n.get("settings.font.resetToSystem"))
            }
          }

        }
        if category == "editor" {
          Section {
            Text(L10n.get("editor.appearance.defaultsHelp"))
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              Text(L10n.get("settings.editor.fontName"))
              Spacer()
              FontPickerControl(fontName: $fontName, fontSize: $fontSize)
            }
            .onChange(of: fontName) { _, name in UserSettings.shared.editorFontName = name }

            HStack {
              Text(L10n.get("editor.letterSpacing"))
              TextField(
                "", value: $letterSpacing, format: .number.precision(.fractionLength(0...1))
              )
              .frame(width: 60)
              .accessibilityLabel(L10n.get("editor.letterSpacing"))
              Text("pt").foregroundStyle(.secondary)
            }
            .onChange(of: letterSpacing) { _, value in
              guard value.isFinite else { return }
              let clamped = min(20, max(-5, value))
              letterSpacing = clamped
              UserSettings.shared.editorLetterSpacing = CGFloat(clamped)
            }

            HStack {
              Text(L10n.editor.fontSize)
              Slider(value: $fontSize, in: 12...24, step: 1)
                .frame(width: 150)
              Text("\(Int(fontSize))pt")
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 40, alignment: .trailing)
            }
            .onChange(of: fontSize) { _, newValue in
              UserSettings.shared.editorFontSize = CGFloat(newValue)
            }

            Picker(L10n.editor.lineSpacing, selection: $lineSpacing) {
              ForEach(LineSpacingOption.allCases) { option in
                Text(option.displayName).tag(option)
              }
            }
            .onChange(of: lineSpacing) { _, newValue in
              UserSettings.shared.editorLineSpacing = newValue.rawValue
            }

          }
        } else if category == "sidebar" {
          Section(L10n.get("settings.sidebar.title")) {
            sidebarSizeRow(
              L10n.get("settings.sidebar.textSize"), value: $sidebarTextSize,
              range: SidebarAppearance.textSizeRange)
            sidebarSizeRow(
              L10n.get("settings.sidebar.iconSize"), value: $sidebarIconSize,
              range: SidebarAppearance.iconSizeRange)
          }

        } else if category == "toolbar" {
          Section(L10n.get("settings.editor.toolbar")) {
            toolbarSizeRow(
              "settings.editor.toolbarIconSize", value: $toolbarIconSize,
              range: EditorToolbarAppearance.sizeRange)
            toolbarSizeRow(
              "settings.editor.toolbarNumberSize", value: $toolbarNumberSize,
              range: EditorToolbarAppearance.sizeRange)
            toolbarSizeRow(
              "settings.editor.toolbarHeight", value: $toolbarHeight,
              range: EditorToolbarAppearance.heightRange)
            Button(L10n.get("settings.editor.toolbarReset")) {
              toolbarIconSize = EditorToolbarAppearance.defaultIconSize
              toolbarNumberSize = EditorToolbarAppearance.defaultNumberSize
              toolbarHeight = EditorToolbarAppearance.defaultHeight
            }
          }

        } else {
          Section(L10n.get("settings.typography.chat")) {
            HStack {
              Text(L10n.get("settings.editor.fontName"))
              Spacer()
              FontPickerControl(fontName: $panelFontName, fontSize: Binding(
                get: { CGFloat(panelFontSize) },
                set: { panelFontSize = min(32, max(10, Double($0))) }
              ))
            }
            toolbarSizeRow("settings.sidebar.textSize", value: $panelFontSize, range: 10...32)
            toolbarSizeRow("editor.lineSpacing", value: $panelLineSpacing, range: 0...16)
            toolbarSizeRow("editor.letterSpacing", value: $panelLetterSpacing, range: -2...8)
            Text(L10n.get("settings.typography.preview"))
              .font(
                panelFontName.isEmpty
                  ? .system(size: panelFontSize) : .custom(panelFontName, size: panelFontSize)
              )
              .lineSpacing(panelLineSpacing).tracking(panelLetterSpacing)
              .padding(.vertical, 8)
          }
        }
      }.formStyle(.grouped)
    }
  }
  private func toolbarSizeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    HStack {
      Text(L10n.get(title))
      Slider(value: value, in: range, step: 1).frame(width: 150)
        .accessibilityLabel(L10n.get(title))
      Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0)))) pt")
        .monospacedDigit()
        .foregroundStyle(AppColors.textSecondary)
        .frame(width: 50, alignment: .trailing)
    }
  }
  private func sidebarSizeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text("\(Int(value.wrappedValue.rounded())) pt")
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range, step: 1)
    }
  }

  /// 앱 전역 폰트 선택 패널 표시
  private func showAppFontPanel() {
    let fontPanel = NSFontPanel.shared
    let fontManager = NSFontManager.shared

    // 현재 폰트 설정
    let currentFont: NSFont
    if appFontName.isEmpty {
      currentFont = NSFont.systemFont(ofSize: 13)
    } else {
      currentFont = NSFont(name: appFontName, size: 13) ?? NSFont.systemFont(ofSize: 13)
    }

    fontManager.setSelectedFont(currentFont, isMultiple: false)
    fontManager.target = AppFontPanelDelegate.shared
    fontManager.action = #selector(AppFontPanelDelegate.changeFont(_:))

    // 폰트 변경 콜백 설정
    AppFontPanelDelegate.shared.onFontChange = { [self] newFont in
      appFontName = newFont.fontName
      UserSettings.shared.appFontName = newFont.fontName
    }

    fontPanel.orderFront(nil)
  }
}

// MARK: - App Font Panel Delegate

/// 앱 전역 폰트 선택용 NSFontPanel 델리게이트
private class AppFontPanelDelegate: NSObject {
  static let shared = AppFontPanelDelegate()

  var onFontChange: ((NSFont) -> Void)?

  @objc func changeFont(_ sender: NSFontManager?) {
    guard let fontManager = sender else { return }

    let currentFont = fontManager.selectedFont ?? NSFont.systemFont(ofSize: 13)
    let newFont = fontManager.convert(currentFont)

    onFontChange?(newFont)
  }
}
