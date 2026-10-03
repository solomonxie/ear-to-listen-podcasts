import SwiftUI

struct ContentView: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @State private var playerLanding: PlayerLanding?
    #if SCREENSHOTS
    @State private var path = NavigationPath()
    #endif

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
            homeStack
            .dockedBottomBar {
                // Hidden behind the player, where it would be a second copy of the same
                // controls sitting on top of the real ones.
                if !engine.isPresentingPlayer {
                    MiniPlayerBar(
                        showingNowPlaying: $engine.isPresentingPlayer,
                        onShowBookmarks: { open(at: .notes) },
                        onTop: { open(at: .top) },
                        onFollow: { open(at: .following) }
                    )
                }
            }

            if engine.isPresentingPlayer {
                RealPlayerView(opensAt: playerLanding)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            MarkFlash().zIndex(2)
        }
        .animation(.easeInOut(duration: 0.28), value: engine.isPresentingPlayer)
        .onChange(of: engine.isPresentingPlayer) { _, isShowing in
            if !isShowing { playerLanding = nil }
        }
        // Attached once, at the root: it works on the window, so every page, sheet and
        // full-screen cover in the app gets it.
        .dismissesKeyboardOnBackgroundTap()
        #if SCREENSHOTS
        .task { await ScreenshotDriver.run(path: $path) { open(at: $0 ?? .top) } }
        #endif
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var homeStack: some View {
        #if SCREENSHOTS
        NavigationStack(path: $path) { HomeView() }
        #else
        NavigationStack { HomeView() }
        #endif
    }

    private func open(at landing: PlayerLanding) {
        playerLanding = landing
        engine.isPresentingPlayer = true
    }
}

/// The whole screen flashes when a moment is marked — a camera's shutter, not a tweak to
/// one button. Same from every bookmark button, wherever it is: a flash on the bar alone
/// was over before anyone saw it, and the big button above the transport had none.
private struct MarkFlash: View {
    @State private var opacity = 0.0

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: .momentMarked)) { _ in
                opacity = 0.45
                withAnimation(.easeOut(duration: 0.7)) { opacity = 0 }
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
