import SwiftUI

/// The bar over Home. Everything it looks like comes from `NowPlayingBarContent`; all this
/// adds is what tapping it does — open the full episode page.
struct MiniPlayerBar: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let track = engine.currentTrack {
            NowPlayingBarContent(
                track: track,
                currentTime: engine.currentTime,
                duration: engine.duration,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onTogglePlay: { engine.togglePlayPause() },
                onBookmark: { MomentMark.add(to: track, at: engine.currentTime) },
                onTapBar: { showingNowPlaying = true }
            )
        }
    }
}
