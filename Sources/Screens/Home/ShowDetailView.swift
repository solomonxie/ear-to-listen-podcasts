import SwiftUI

struct ShowDetailView: View {
    let show: PodcastShow
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState

    private var episodes: [PodcastEpisode] { library.episodes(forShow: show.id) }
    private var speakers: [Speaker] { show.speakerIDs.compactMap(library.speaker) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(show.artColor.gradient)
                        .frame(height: 160)
                        .overlay { Image(systemName: show.symbol).font(.system(size: 48)).foregroundStyle(.white) }
                    Text(show.summary).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(speakers) { speaker in
                            Text(speaker.name).font(.caption.weight(.semibold))
                        }
                        Spacer()
                        Button(library.savedShowIDs.contains(show.id) ? "Saved" : "Save") {
                            if library.savedShowIDs.contains(show.id) {
                                library.savedShowIDs.remove(show.id)
                            } else {
                                library.savedShowIDs.insert(show.id)
                            }
                        }
                        .buttonStyle(.bordered)
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
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EpisodeRow: View {
    let episode: PodcastEpisode
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.title).font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Text(Self.formattedDuration(episode.durationSeconds))
                if episode.audioFileName != nil {
                    Label("Transcript", systemImage: "text.bubble")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
