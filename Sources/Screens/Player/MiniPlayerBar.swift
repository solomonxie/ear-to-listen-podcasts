import SwiftUI

/// The bar over Home. Everything it looks like comes from `NowPlayingBarContent`, so
/// "what's playing" is the same object wherever you meet it; all this adds is what tapping
/// it does — open the full episode page, where the docked copy scrolls that page back to the
/// top — and the artist/album lookup Home doesn't otherwise have to hand.
struct MiniPlayerBar: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @Binding var showingNowPlaying: Bool
    @State private var artistName: String?
    @State private var albumName: String?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        if let track = engine.currentTrack {
            NowPlayingBarContent(
                track: track,
                artistName: artistName,
                albumName: albumName,
                currentTime: engine.currentTime,
                duration: engine.duration,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onTogglePlay: { engine.togglePlayPause() },
                onTapBar: { showingNowPlaying = true }
            )
            .task(id: track.id) {
                artistName = track.artistID.flatMap { try? libraryStore.artist(id: $0) }?.name
                albumName = track.albumID.flatMap { try? libraryStore.album(id: $0) }?.name
            }
        }
    }
}
