import SwiftUI

// MARK: - Shortcut Edit Sheet

struct ShortcutEditSheet: View {
    let binding: ShortcutBinding
    let onSave: (ShortcutBinding) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shortcutManager = KeyboardShortcutManager.shared

    @State private var key: String
    @State private var useCommand: Bool
    @State private var useShift: Bool
    @State private var useOption: Bool
    @State private var useControl: Bool
    @State private var conflictBinding: ShortcutBinding? = nil

    init(binding: ShortcutBinding, onSave: @escaping (ShortcutBinding) -> Void) {
        self.binding = binding
        self.onSave = onSave

        _key = State(initialValue: binding.key)
        _useCommand = State(initialValue: binding.modifiers.contains(.command))
        _useShift = State(initialValue: binding.modifiers.contains(.shift))
        _useOption = State(initialValue: binding.modifiers.contains(.option))
        _useControl = State(initialValue: binding.modifiers.contains(.control))
    }

    private var currentModifiers: ModifierKeys {
        var modifiers: ModifierKeys = []
        if useCommand { modifiers.insert(.command) }
        if useShift { modifiers.insert(.shift) }
        if useOption { modifiers.insert(.option) }
        if useControl { modifiers.insert(.control) }
        return modifiers
    }

    private var previewString: String {
        let keyDisplay = key.isEmpty ? "?" : (key.count == 1 ? key.uppercased() : key.capitalized)
        return "\(currentModifiers.displayString)\(keyDisplay)"
    }

    var body: some View {
        VStack(spacing: 20) {
            // 헤더
            Text(L10n.get("settings.shortcuts.editTitle"))
                .font(.headline)

            Text(binding.action.displayName)
                .foregroundStyle(AppColors.textSecondary)

            Divider()

            // 단축키 미리보기
            Text(previewString)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .padding()
                .background(AppColors.controlBackground)
                .cornerRadius(8)

            // 충돌 경고
            if let conflict = conflictBinding {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warningIndicator)
                    Text(String(format: L10n.get("settings.shortcuts.conflict"), conflict.action.displayName))
                        .foregroundStyle(AppColors.textSecondary)
                        .font(.caption)
                }
            }

            // 키 입력
            HStack {
                Text(L10n.get("settings.shortcuts.key"))
                    .frame(width: 80, alignment: .trailing)

                TextField("", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: key) { _, newValue in
                        checkConflict()
                    }
            }

            // 수정자 키
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.get("settings.shortcuts.modifiers"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)

                HStack(spacing: 16) {
                    Toggle("⌘ Command", isOn: $useCommand)
                        .onChange(of: useCommand) { _, _ in checkConflict() }
                    Toggle("⇧ Shift", isOn: $useShift)
                        .onChange(of: useShift) { _, _ in checkConflict() }
                }

                HStack(spacing: 16) {
                    Toggle("⌥ Option", isOn: $useOption)
                        .onChange(of: useOption) { _, _ in checkConflict() }
                    Toggle("⌃ Control", isOn: $useControl)
                        .onChange(of: useControl) { _, _ in checkConflict() }
                }
            }
            .toggleStyle(.checkbox)

            Divider()

            // 버튼
            HStack {
                Button(L10n.get("settings.shortcuts.resetToDefault")) {
                    shortcutManager.resetToDefault(for: binding.action)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(L10n.common.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.common.save) {
                    var updatedBinding = binding
                    updatedBinding.key = key
                    updatedBinding.modifiers = currentModifiers
                    onSave(updatedBinding)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || conflictBinding != nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            checkConflict()
        }
    }

    private func checkConflict() {
        conflictBinding = shortcutManager.findConflict(
            key: key,
            modifiers: currentModifiers,
            excluding: binding.action
        )
    }
}
