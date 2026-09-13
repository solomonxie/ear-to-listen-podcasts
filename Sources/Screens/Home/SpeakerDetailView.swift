import SwiftUI

struct SpeakerDetailView: View {
    let speaker: Speaker
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState

    private var shows: [PodcastShow] { library.shows.filter { $0.speakerIDs.contains(speaker.id) } }
    private var episodes: [PodcastEpisode] { library.episodes(forSpeaker: speaker.id) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 96, height: 96)
                        .overlay { Image(systemName: "person.fill").font(.system(size: 40)).foregroundStyle(.secondary) }
                    Text(speaker.bio).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(shows) { show in Text(show.title).font(.caption.weight(.semibold)) }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Episodes") {
                ForEach(episodes) { episode in
                    Button {
                        playback.play(episode, queue: episodes)
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(speaker.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
