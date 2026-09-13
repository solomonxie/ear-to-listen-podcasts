import SwiftUI

struct PlaylistDetailView: View {
    let playlist: PlaylistUI
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState

    private var episodes: [PodcastEpisode] { library.episodes(inPlaylist: playlist) }

    var body: some View {
        Group {
            if episodes.isEmpty {
                ContentUnavailableView("No episodes yet", systemImage: "mic.slash")
            } else {
                List(episodes) { episode in
                    Button {
                        playback.play(episode, queue: episodes)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
    }
}
