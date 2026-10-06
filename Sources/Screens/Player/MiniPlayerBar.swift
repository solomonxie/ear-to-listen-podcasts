import SwiftUI

/// The bar over Home. Everything it looks like comes from `NowPlayingBarContent`; all this
/// adds is what tapping it does — open the full episode page.
struct MiniPlayerBar: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @Binding var showingNowPlaying: Bool
    let onShowBookmarks: () -> Void
    let onFollow: () -> Void
    @State private var bookmarkCount = 0

    var body: some View {
        if let track = engine.currentTrack {
            NowPlayingBarContent(
                track: track,
                currentTime: engine.currentTime,
                duration: engine.duration,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onSkipForward: { engine.skip(by: 10) },
                onTogglePlay: { engine.togglePlayPause() },
                bookmarkCount: bookmarkCount,
                onBookmark: { MomentMark.add(to: track, at: engine.currentTime) },
                onShowBookmarks: onShowBookmarks,
                onTapBar: { showingNowPlaying = true },
                onSeek: { engine.seek(to: $0) },
                onFollow: onFollow
            )
            .task(id: track.id) { bookmarkCount = MomentMark.count(forTrack: track.id) }
            .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
                bookmarkCount = MomentMark.count(forTrack: track.id)
            }
        }
    }
}
