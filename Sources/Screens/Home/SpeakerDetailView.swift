import SwiftUI

struct SpeakerDetailView: View {
    let speaker: Speaker
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState
    @State private var showingEdit = false

    private var currentSpeaker: Speaker { library.speaker(speaker.id) ?? speaker }
    private var shows: [PodcastShow] { library.shows.filter { $0.speakerIDs.contains(speaker.id) } }
    private var albums: [PodcastAlbum] { library.albums(forSpeaker: speaker.id) }
    private var episodes: [PodcastEpisode] { library.episodes(forSpeaker: speaker.id) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 96, height: 96)
                        .overlay { Image(systemName: "person.fill").font(.system(size: 40)).foregroundStyle(.secondary) }
                    Text(currentSpeaker.bio).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        ForEach(shows) { show in Text(show.title).font(.caption.weight(.semibold)) }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Albums") {
                if albums.isEmpty {
                    Text("No albums yet").foregroundStyle(.secondary)
                }
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        AlbumRow(album: album)
                    }
                }
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
        .navigationTitle(currentSpeaker.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            SpeakerEditView(speaker: currentSpeaker)
        }
    }
}

struct AlbumRow: View {
    let album: PodcastAlbum
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(album.artColor.gradient)
                .frame(width: 40, height: 40)
                .overlay { Image(systemName: album.symbol).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.subheadline.weight(.semibold))
                Text("\(album.episodeIDs.count) episodes").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
