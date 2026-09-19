import SwiftUI

// MARK: - General Settings

struct GeneralSettingsView: View {
    @State private var selectedLanguage = LocalizationManager.shared.currentLanguage
    @State private var launchBehavior = UserSettings.shared.appLaunchBehavior
    @State private var appTheme = UserSettings.shared.appTheme
    @State private var permissionManager = PermissionManager.shared
    @State private var projectManager = ProjectManager.shared

    /// 테마 변경 다이얼로그 표시 여부
    @State private var showThemeChangeDialog = false
    /// 선택된 새 테마 (다이얼로그 표시용)
    @State private var pendingTheme: AppTheme?

    /// 저장된 테마가 현재 적용된 테마와 다른지 확인
    private var themeWillChangeOnRestart: Bool {
        appTheme != ThemeManager.shared.appliedTheme
    }

    var body: some View {
        Form {
            UpdateSettingsSection()
            // 언어 및 테마 설정
            Section {
                Picker(L10n.get("settings.language"), selection: $selectedLanguage) {
                    ForEach(LocalizationManager.Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .onChange(of: selectedLanguage) { _, newValue in
                    LocalizationManager.shared.currentLanguage = newValue
                }

                // 테마 설정
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L10n.get("settings.theme"), selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .onChange(of: appTheme) { oldValue, newValue in
                        // 현재 적용된 테마와 다른 테마를 선택한 경우 다이얼로그 표시
                        if newValue != ThemeManager.shared.appliedTheme {
                            pendingTheme = newValue
                            showThemeChangeDialog = true
                        }
                    }

                    // 재시작 안내 문구
                    if themeWillChangeOnRestart {
                        Text(L10n.get("settings.theme.willApplyOnRestart"))
                            .font(.caption)
                            .foregroundStyle(AppColors.accent)
                    }
                }
                .alert(L10n.get("settings.theme.changeTitle"), isPresented: $showThemeChangeDialog) {
                    Button(L10n.get("settings.theme.later")) {
                        // 테마 설정 저장 (다음 재시작 시 적용)
                        if let theme = pendingTheme {
                            UserSettings.shared.appTheme = theme
                        }
                        pendingTheme = nil
                    }
                    Button(L10n.get("settings.theme.quit"), role: .destructive) {
                        // 테마 설정 저장 후 앱 종료
                        if let theme = pendingTheme {
                            UserSettings.shared.appTheme = theme
                        }
                        pendingTheme = nil
                        NSApplication.shared.terminate(nil)
                    }
                } message: {
                    Text(L10n.get("settings.theme.changeMessage"))
                }

                // 시작 동작 설정
                Picker(L10n.get("settings.launch.title"), selection: $launchBehavior) {
                    ForEach(AppLaunchBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .onChange(of: launchBehavior) { _, newValue in
                    UserSettings.shared.appLaunchBehavior = newValue
                }
            }

            // 이용약관
            Section {
                Button {
                    TermsWindowController.shared.openTermsWindow()
                } label: {
                    HStack {
                        Label(L10n.get("terms.title"), systemImage: "doc.text")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(AppColors.toolbarIcon)
                    }
                }
                .buttonStyle(.plain)
            }

            // 폴더 접근 권한
            Section {
                if permissionManager.authorizedDirectories.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 28))
                                .foregroundStyle(AppColors.toolbarIcon)
                            Text(L10n.get("settings.permissions.noFolders"))
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    ForEach(permissionManager.authorizedDirectories) { directory in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(AppColors.accent)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(directory.displayName)
                                    .font(.body)
                                Text(directory.path)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button {
                                permissionManager.removeDirectoryAccess(directory)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppColors.toolbarIcon)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.common.delete)
                        }
                    }
                }

                Button {
                    permissionManager.addDirectoryAccess()
                } label: {
                    Label(L10n.get("settings.permissions.addFolder"), systemImage: "plus")
                }
            } header: {
                Text(L10n.get("settings.permissions.title"))
            } footer: {
                Text(L10n.get("settings.permissions.description"))
            }
        }
        .formStyle(.grouped)
    }

}
