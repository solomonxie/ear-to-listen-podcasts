import SwiftUI

struct ContentView: View {
    @StateObject private var playbackMock = PlaybackMockState.shared
    @StateObject private var library = MockLibraryStore.shared
    @State private var showingNowPlaying = false

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar(showingNowPlaying: $showingNowPlaying)
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
        }
        .environmentObject(playbackMock)
        .environmentObject(library)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
