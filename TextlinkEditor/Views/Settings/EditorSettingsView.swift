import SwiftUI

// MARK: - Editor Settings

struct EditorSettingsView: View {
    @AppStorage(EditorRulerAppearance.widthKey, store: EditorRulerAppearance.store)
    private var rulerWidth = EditorRulerAppearance.defaultWidth
    @State private var autoSaveOption: AutoSaveOption = UserSettings.shared.autoSaveOption
    @State private var rememberCursorPosition: Bool = UserSettings.shared.rememberCursorPosition

    var body: some View {
        Form {
            Section {
                Picker(L10n.get("settings.autoSave"), selection: $autoSaveOption) {
                    ForEach(AutoSaveOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: autoSaveOption) { _, newValue in
                    UserSettings.shared.autoSaveOption = newValue
                }

                HStack {
                    Text(L10n.get("settings.editor.lineNumberWidth"))
                    Slider(value: Binding(
                        get: { EditorRulerAppearance.bounded(rulerWidth) },
                        set: { rulerWidth = EditorRulerAppearance.bounded($0) }
                    ), in: EditorRulerAppearance.widthRange, step: 1)
                    .frame(width: 150)
                    .accessibilityLabel(L10n.get("settings.editor.lineNumberWidth"))
                    Text("\(Int(EditorRulerAppearance.bounded(rulerWidth))) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                Toggle(L10n.get("settings.rememberCursorPosition"), isOn: $rememberCursorPosition)
                    .onChange(of: rememberCursorPosition) { _, newValue in
                        UserSettings.shared.rememberCursorPosition = newValue
                    }
            }
        }
        .formStyle(.grouped)
    }

}
