import SwiftUI

// MARK: - Developer Settings

struct DeveloperSettingsView: View {
    @State private var aiTerminalMode = UserSettings.shared.aiTerminalMode

    var body: some View {
        Form {
            Section {
                Text(L10n.get("settings.ai.structuredMode"))
                if aiTerminalMode {
                    Button(L10n.get("settings.ai.disableTerminal")) {
                        UserSettings.shared.aiTerminalMode = false
                        aiTerminalMode = false
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
