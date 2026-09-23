import SwiftUI

/// The bar over Home. Same shape as the one docked on the player — see
/// `NowPlayingBarContent` — so "what's playing" looks the same wherever you meet it, down
/// to the bookmark. Here tapping the bar opens the full episode page; there it scrolls
/// that page back to the top.
struct MiniPlayerBar: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @Binding var showingNowPlaying: Bool
    @State private var artistName: String?
    @State private var albumName: String?
    @State private var bookmarkCount = 0

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        if let track = engine.currentTrack {
            NowPlayingBarContent(
                track: track,
                artistName: artistName,
                albumName: albumName,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onTogglePlay: { engine.togglePlayPause() },
                onTapBar: { showingNowPlaying = true },
                // The episode keeps playing while you browse, and a moment worth keeping
                // doesn't wait for you to open the player first. Marks and stays put, so
                // pressing it never takes the page you're on away from you.
                onBookmark: {
                    MomentMark.add(to: track, at: engine.currentTime)
                    bookmarkCount = MomentMark.count(forTrack: track.id)
                },
                bookmarkCount: bookmarkCount
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
                bookmarkCount = MomentMark.count(forTrack: track.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
                bookmarkCount = MomentMark.count(forTrack: track.id)
            }
        }
    }
}
