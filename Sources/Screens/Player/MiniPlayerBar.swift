import SwiftUI

/// The bar over Home. Same shape as the one docked on the player — see
/// `NowPlayingBarContent` — so "what's playing" looks the same wherever you meet it. Here
/// tapping it opens the full episode page; there it scrolls that page back to the top.
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
                isPlaying: engine.isPlaying,
                onTogglePlay: { engine.togglePlayPause() },
                onTapBar: { showingNowPlaying = true }
            )
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                ProgressView(value: engine.duration > 0 ? engine.currentTime / engine.duration : 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 1.5)
            }
            .task(id: track.id) {
                artistName = track.artistID.flatMap { try? libraryStore.artist(id: $0) }?.name
                albumName = track.albumID.flatMap { try? libraryStore.album(id: $0) }?.name
            }
        }
    }
}
