import SwiftUI

@main
struct EarToListenApp: App {
    @StateObject private var playback = PlaybackEngine.shared
    @StateObject private var language = AppLanguageStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CloudProviderRegistry.shared.register(type: S3Provider.providerType) { try S3Provider(config: $0) }
        CloudProviderRegistry.shared.register(type: LocalFilesProvider.providerType) { try LocalFilesProvider(config: $0) }
        CloudProviderRegistry.shared.register(type: DemoProvider.providerType) { _ in DemoProvider() }
        PlaylistImportSourceRegistry.shared.register(SpotifyImportSource())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // A reinstall gets its data back before anything is shown, without being
                // asked — on a first launch there's no context for that question.
                .task { await FirstRunRestore.runIfNeeded() }
                .environmentObject(playback)
                .environmentObject(language)
                // Drives which localization every `Text("…")` resolves to, so the picker
                // in Settings takes effect without a relaunch.
                .environment(\.locale, language.locale)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            // Auto-sync only runs in the foreground — no background-refresh entitlement.
            if newPhase == .active {
                SyncScheduler.shared.start()
                AutoBackup.shared.start()
                // A transcription pass the system took down while the app was away picks
                // up where it stopped, rather than waiting to be asked again.
                TranscriptRunner.shared.resumeIfInterrupted()
            } else {
                SyncScheduler.shared.stop()
                AutoBackup.shared.stop()
                // Leaving the app is the moment nothing is mid-write, so it's when the
                // copies that stay on the phone are taken. At most once a day, and only if
                // something was written — see `LocalBackups`.
                LocalBackups.runIfDue { try BackupService().currentArchive() }
            }
        }
    }
}
