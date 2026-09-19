import SwiftUI

struct UpdateSettingsSection: View {
    @State private var manager = AppUpdateManager.shared
    @State private var key = ""

    var body: some View {
        Section(L10n.get("updates.title")) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Text(L10n.get(manager.statusKey))
            if !manager.detail.isEmpty {
                Text(manager.detail).font(.caption).foregroundStyle(.secondary)
            }
            if AppUpdateManager.isEnabled {
                SecureField(L10n.get(manager.hasAppKey ? "updates.replaceKey" : "updates.appKey"), text: $key)
                HStack {
                    Button(L10n.get("updates.saveKey")) {
                        let submitted = key
                        key = ""
                        Task { await manager.saveKey(submitted) }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.busy)
                    Button(L10n.get("updates.check")) { Task { await manager.check() } }
                        .disabled(manager.busy)
                }
            }
            if AppUpdateManager.isEnabled {
                Text(L10n.get("updates.privacy")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
