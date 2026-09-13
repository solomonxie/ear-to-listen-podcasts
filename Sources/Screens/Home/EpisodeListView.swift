import SwiftUI

/// Shared list used for year/topic browsing from Home.
struct EpisodeListView: View {
    let title: String
    let episodes: [PodcastEpisode]
    @EnvironmentObject private var playback: PlaybackMockState

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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
