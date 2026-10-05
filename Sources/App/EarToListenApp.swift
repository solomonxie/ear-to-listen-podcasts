import SwiftUI

@main
struct EarToListenApp: App {
    @StateObject private var playback = PlaybackEngine.shared
    @StateObject private var language = AppLanguageStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Every cloud the app can talk to, from the one list of them. S3, COS and OSS
        // are the same client against three hostnames; Azure and Google each need their
        // own.
        for kind in CloudSourceKind.allCases {
            switch kind {
            case .amazonS3, .tencentCos, .aliyunOss:
                CloudProviderRegistry.shared.register(type: kind.providerType) { try S3Provider(config: $0) }
            case .azureBlob:
                CloudProviderRegistry.shared.register(type: kind.providerType) { try AzureBlobProvider(config: $0) }
            case .googleCloudStorage:
                CloudProviderRegistry.shared.register(type: kind.providerType) { try GoogleCloudStorageProvider(config: $0) }
            }
        }
        CloudProviderRegistry.shared.register(type: LocalFilesProvider.providerType) { try LocalFilesProvider(config: $0) }
        PlaylistImportSourceRegistry.shared.register(SpotifyImportSource())
        CloudProviderRegistry.shared.register(type: DemoProvider.providerType) { _ in DemoProvider() }
        SearchReturnKey.useDone()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // A reinstall gets its data back before anything is shown, without being
                // asked — on a first launch there's no context for that question.
                .task { await FirstRunRestore.runIfNeeded() }
                .task(priority: .utility) { await AppStorefront.refresh() }
                .environmentObject(playback)
                .environmentObject(language)
                // Drives which localization every `Text("…")` resolves to, so the picker
                // in Settings takes effect without a relaunch.
                .environment(\.locale, language.locale)
        }
        .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
            // Auto-sync only runs in the foreground — no background-refresh entitlement.
            if newPhase == .active {
                SyncScheduler.shared.start()
                LibraryMaintenance.runOnce()
                ScreenAwake.apply()
                Task { await YouTubeEpisodes.openShared() }
                AutoBackup.shared.refreshCloudDriveStatus()
                // A transcription pass the system took down while the app was away picks
                // up where it stopped, rather than waiting to be asked again.
                TranscriptRunner.shared.resumeIfInterrupted()
            } else {
                SyncScheduler.shared.stop()
                // Leaving the app is when an owed backup goes out, rather than waiting for
                // the next edit. Only on a real move into the background: the `initial`
                // call at launch arrives with the phase the app starts in, which isn't
                // `.active`, and a backup there sat in front of Home.
                if newPhase == .background, oldPhase != newPhase { AutoBackup.shared.backUpOnLeaving() }
            }
        }
    }
}
