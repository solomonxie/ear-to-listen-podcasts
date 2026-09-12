import SwiftUI

@main
struct BringYourOwnMusicApp: App {
    @StateObject private var playback = PlaybackEngine.shared

    init() {
        CloudProviderRegistry.shared.register(type: S3Provider.providerType) { try S3Provider(config: $0) }
        PlaylistImportSourceRegistry.shared.register(SpotifyImportSource())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playback)
        }
    }
}
