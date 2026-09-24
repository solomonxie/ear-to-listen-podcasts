import SwiftUI

struct ContentView: View {
    @ObservedObject private var engine = PlaybackEngine.shared

    var body: some View {
        // One place shows the player, so tapping an episode behaves the same wherever you
        // tapped it.
        //
        // **A sibling in a ZStack, not a `fullScreenCover`.** A cover's transition is always
        // vertical — up to present, down to dismiss — so the page still slid downwards out
        // of view however it had been left, which read as a card being put down a moment
        // after swiping right to go back from it. There is no way to give a cover a
        // different transition, so it isn't one: it moves in from the trailing edge and
        // leaves the same way, which is what the swipe and the ‹ both promise.
        //
        // Its own `NavigationStack` is fine here — it is beside Home's, not inside it.
        ZStack {
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

            if engine.isPresentingPlayer {
                RealPlayerView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: engine.isPresentingPlayer)
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
