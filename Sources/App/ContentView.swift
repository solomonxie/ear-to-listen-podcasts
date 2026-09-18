import SwiftUI

struct ContentView: View {
    @ObservedObject private var engine = PlaybackEngine.shared

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .safeAreaInset(edge: .bottom) {
            // Hidden behind the player, where it would be a second copy of the same
            // controls sitting on top of the real ones.
            if !engine.isPresentingPlayer {
                MiniPlayerBar(showingNowPlaying: $engine.isPresentingPlayer)
            }
        }
        // One place presents the player, so tapping an episode behaves the same wherever
        // you tapped it. A whole page rather than a card: it holds a full transcript, and
        // a sheet's downward drag fought the text under the finger for every swipe.
        .fullScreenCover(isPresented: $engine.isPresentingPlayer) {
            RealPlayerView()
        }
        // Attached once, at the root: it works on the window, so every page, sheet and
        // full-screen cover in the app gets it.
        .dismissesKeyboardOnBackgroundTap()
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
