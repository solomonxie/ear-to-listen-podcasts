import SwiftUI

struct ContentView: View {
    @ObservedObject private var engine = PlaybackEngine.shared

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar(showingNowPlaying: $engine.isPresentingPlayer)
        }
        // One place presents the player, so tapping an episode behaves the same wherever
        // you tapped it.
        .sheet(isPresented: $engine.isPresentingPlayer) {
            RealPlayerView()
                // Without a handle there's nothing to grab, and with a transcript under
                // the finger a downward drag scrolls the text rather than dismissing.
                .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
