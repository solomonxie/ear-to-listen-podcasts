import SwiftUI

struct ContentView: View {
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar(showingNowPlaying: $showingNowPlaying)
        }
        .sheet(isPresented: $showingNowPlaying) {
            RealPlayerView()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
