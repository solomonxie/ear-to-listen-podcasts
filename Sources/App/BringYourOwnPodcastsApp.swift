import SwiftUI

@main
struct BringYourOwnPodcastsApp: App {
    @StateObject private var playback = PlaybackEngine.shared
    @StateObject private var language = AppLanguageStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CloudProviderRegistry.shared.register(type: S3Provider.providerType) { try S3Provider(config: $0) }
        CloudProviderRegistry.shared.register(type: LocalFilesProvider.providerType) { try LocalFilesProvider(config: $0) }
        CloudProviderRegistry.shared.register(type: DemoProvider.providerType) { _ in DemoProvider() }
        PlaylistImportSourceRegistry.shared.register(SpotifyImportSource())
        DemoDataSeeder.seedOnFirstLaunchIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
            } else {
                SyncScheduler.shared.stop()
            }
        }
    }
}
