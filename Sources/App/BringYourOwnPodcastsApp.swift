import SwiftUI

@main
struct BringYourOwnPodcastsApp: App {
    @StateObject private var playback = PlaybackEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CloudProviderRegistry.shared.register(type: S3Provider.providerType) { try S3Provider(config: $0) }
        CloudProviderRegistry.shared.register(type: LocalFilesProvider.providerType) { try LocalFilesProvider(config: $0) }
        PlaylistImportSourceRegistry.shared.register(SpotifyImportSource())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playback)
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
