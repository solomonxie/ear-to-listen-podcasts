import SwiftUI

/// Settings, the overview: what's used often is a row here, and everything with more than
/// a switch to it is one tap further in.
///
/// ```
///  LIBRARY            BACKUP              AI           GENERAL          ABOUT
///  ⚑ Flagged   12 ›   ☁ iCloud Drive [●]  ✦ Keys  2 ›   🌐 Language ⌄    ⓘ About 1.0 ›
///  👁 Neglected    ›   ⟲ Backup & Restore ›              ☀ Screen on [ ]
///  🕘 Fix history  ›                                     ◐ Demo mode [ ]
/// ```
struct SettingsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var autoBackup = AutoBackup.shared
    @EnvironmentObject private var language: AppLanguageStore
    @State private var openPicker: String?
    @State private var isDemo = AppMode.isDemo
    @AppStorage(ScreenAwake.key) private var keepsScreenOn = false

    /// Version and build as shipped, so a bug report can name the build it came from.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var lastBackup: String? {
        guard autoBackup.isCloudDriveEnabled, let last = autoBackup.lastCloudDriveBackupAt else { return nil }
        return last.formatted(.relative(presentation: .named))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "LIBRARY") {
                NavigationLink { FlaggedItemsView() } label: {
                    SettingsRow(icon: "flag.fill", tint: .orange, title: "Flagged items",
                                value: viewModel.flagged.total > 0 ? "\(viewModel.flagged.total)" : nil)
                }
                SettingsDivider()
                NavigationLink { NeglectedItemsView() } label: {
                    SettingsRow(icon: "eye.slash.fill", tint: .gray, title: "Neglected items")
                }
                SettingsDivider()
                NavigationLink { FixHistoryView() } label: {
                    SettingsRow(icon: "clock.arrow.circlepath", tint: .indigo, title: "Fix history")
                }
            }

            SettingsGroup(title: "BACKUP") {
                SettingsToggleRow(icon: "icloud.fill", tint: .blue, title: "iCloud Drive", isOn: $autoBackup.isCloudDriveEnabled)
                    .disabled(!autoBackup.cloudDriveStatus.isReady)
                SettingsDivider()
                NavigationLink { BackupSettingsView(viewModel: viewModel) } label: {
                    SettingsRow(icon: "arrow.triangle.2.circlepath", tint: .teal, title: "Backup & Restore", value: lastBackup)
                }
            }

            SettingsGroup(title: "AI") {
                NavigationLink { AiKeysSettingsView(viewModel: viewModel) } label: {
                    SettingsRow(icon: "sparkles", tint: .purple, title: "AI Keys",
                                value: viewModel.aiKeys.isEmpty ? "None" : "\(viewModel.aiKeys.count)")
                }
            }

            SettingsGroup(title: "GENERAL") {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "globe", tint: .green)
                    UnfoldingPicker(
                        title: "Language", id: "appLanguage", open: $openPicker,
                        selection: $language.language,
                        options: AppLanguage.allCases.map { UnfoldingPicker.Option($0, $0.displayName) }
                    )
                }
                .padding(.vertical, 6)
                SettingsDivider()
                SettingsToggleRow(icon: "sun.max.fill", tint: .yellow, title: "Keep screen on", isOn: $keepsScreenOn)
                    .onChange(of: keepsScreenOn) { _, _ in ScreenAwake.apply() }
                SettingsDivider()
                SettingsToggleRow(icon: "theatermasks.fill", tint: .pink, title: "Demo mode", isOn: $isDemo)
                    .onChange(of: isDemo) { _, on in
                        guard on != AppMode.isDemo else { return }
                        do {
                            try on ? DemoMode.enter() : DemoMode.leave()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                            isDemo = AppMode.isDemo
                        }
                        viewModel.load()
                    }
            }

            SettingsGroup(title: "ABOUT") {
                NavigationLink { AboutSettingsView(viewModel: viewModel) } label: {
                    SettingsRow(icon: "info.circle.fill", tint: .gray, title: "About Ear to Listen", value: appVersion)
                }
            }
        }
        .sectionRow()
        // The docked mini player sits over the end of the page, and Settings is the end
        // of the page — without this the last group is half a bar short of readable.
        .padding(.bottom, 72)
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}
