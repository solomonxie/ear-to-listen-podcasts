import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            NowPlayingView()
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
            QueueView()
                .tabItem { Label("Queue", systemImage: "list.number") }
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "rectangle.stack") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine.shared)
}
