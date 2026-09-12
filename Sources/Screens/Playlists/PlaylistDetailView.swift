import SwiftUI

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    @Published var tracks: [Track] = []
    let playlist: Playlist

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(playlist: Playlist) {
        self.playlist = playlist
    }

    func load() {
        tracks = (try? playlistStore.tracks(inPlaylist: playlist.id)) ?? []
    }
}

struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    @EnvironmentObject private var playback: PlaybackEngine

    init(playlist: Playlist) {
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    var body: some View {
        Group {
            if viewModel.tracks.isEmpty {
                ContentUnavailableView("No tracks yet", systemImage: "music.note.list")
            } else {
                List(viewModel.tracks) { track in
                    Button(track.title) {
                        playback.play(track: track, queue: viewModel.tracks)
                    }
                }
            }
        }
        .navigationTitle(viewModel.playlist.name)
        .onAppear { viewModel.load() }
    }
}
