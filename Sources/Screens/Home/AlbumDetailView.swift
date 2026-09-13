import SwiftUI

struct AlbumDetailView: View {
    let album: PodcastAlbum
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState

    private var episodes: [PodcastEpisode] { library.episodes(forAlbum: album) }
    private var speakers: [Speaker] { album.speakerIDs.compactMap(library.speaker) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(album.artColor.gradient)
                        .frame(height: 160)
                        .overlay { Image(systemName: album.symbol).font(.system(size: 48)).foregroundStyle(.white) }
                    Text(album.description).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(speakers) { speaker in
                            Text(speaker.name).font(.caption.weight(.semibold))
                        }
                        Spacer()
                        Text(album.releaseDate, format: .dateTime.year().month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let first = episodes.first {
                        Button {
                            playback.play(first, queue: episodes)
                        } label: {
                            Label("Play latest", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
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
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
