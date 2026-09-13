import SwiftUI

/// Single-page root: search up top, then Home/Library shelves, then Remote and
/// Settings sections — no tab bar, everything reachable by scrolling.
struct HomeView: View {
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState
    @StateObject private var settings = SettingsViewModel()

    @State private var query = ""
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var years: [Int] {
        Array(Set(library.episodes.map(\.publishedYear))).sorted(by: >)
    }
    private var favoriteShows: [PodcastShow] {
        library.shows.filter { library.savedShowIDs.contains($0.id) }
    }
    private var downloadedEpisodes: [PodcastEpisode] {
        library.episodes.filter { library.downloadedEpisodeIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !query.isEmpty {
                    searchResults
                } else {
                    homeShelves
                    Divider().padding(.horizontal)
                    RemoteSectionView(viewModel: settings)
                    Divider().padding(.horizontal)
                    SettingsSectionView(viewModel: settings)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Good listening")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your podcasts")
        .onAppear { settings.load() }
        .alert("New Playlist", isPresented: $showingCreatePlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                guard !newPlaylistName.isEmpty else { return }
                library.createPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var homeShelves: some View {
        shelf("Continue Listening") {
            ForEach(downloadedEpisodes) { episode in
                EpisodeCard(episode: episode)
            }
        }

        shelf("Albums") {
            ForEach(library.albums) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Playlists", trailing: {
            Button { showingCreatePlaylist = true } label: { Image(systemName: "plus.circle.fill") }
        }) {
            ForEach(library.playlists) { playlist in
                NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Favorites") {
            ForEach(favoriteShows) { show in
                NavigationLink { ShowDetailView(show: show) } label: {
                    ShowCard(show: show)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Speakers") {
            ForEach(library.speakers) { speaker in
                NavigationLink { SpeakerDetailView(speaker: speaker) } label: {
                    SpeakerCard(speaker: speaker)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Downloaded") {
            ForEach(downloadedEpisodes) { episode in
                EpisodeCard(episode: episode)
            }
        }

        shelf("Browse by Year") {
            ForEach(years, id: \.self) { year in
                NavigationLink {
                    EpisodeListView(title: "\(year)", episodes: library.episodes.filter { $0.publishedYear == year })
                } label: {
                    ChipCard(title: "\(year)", color: .gray)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Topics") {
            ForEach(library.topics) { topic in
                NavigationLink {
                    let showIDs = Set(library.shows.filter { $0.topicIDs.contains(topic.id) }.map(\.id))
                    EpisodeListView(title: topic.name, episodes: library.episodes.filter { showIDs.contains($0.showID) })
                } label: {
                    ChipCard(title: topic.name, color: topic.color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var matchedShows: [PodcastShow] { library.shows.filter { $0.title.localizedCaseInsensitiveContains(query) } }
    private var matchedSpeakers: [Speaker] { library.speakers.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedAlbums: [PodcastAlbum] { library.albums.filter { $0.title.localizedCaseInsensitiveContains(query) } }
    private var matchedPlaylists: [PlaylistUI] { library.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedTopics: [Topic] { library.topics.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedEpisodes: [PodcastEpisode] {
        library.episodes.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }
    private var hasResults: Bool {
        !(matchedShows.isEmpty && matchedSpeakers.isEmpty && matchedAlbums.isEmpty && matchedPlaylists.isEmpty && matchedEpisodes.isEmpty && matchedTopics.isEmpty)
    }

    @ViewBuilder
    private var searchResults: some View {
        if !hasResults {
            ContentUnavailableView.search(text: query)
                .padding(.top, 40)
        } else {
            resultSection("Shows", matchedShows) { show in
                NavigationLink { ShowDetailView(show: show) } label: {
                    resultRow(symbol: show.symbol, color: show.artColor, title: show.title, subtitle: "\(show.year)")
                }
            }
            resultSection("Speakers", matchedSpeakers) { speaker in
                NavigationLink { SpeakerDetailView(speaker: speaker) } label: {
                    resultRow(symbol: "person.fill", color: .gray, title: speaker.name, subtitle: nil)
                }
            }
            resultSection("Albums", matchedAlbums) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    resultRow(symbol: album.symbol, color: album.artColor, title: album.title, subtitle: "\(album.episodeIDs.count) episodes")
                }
            }
            resultSection("Playlists", matchedPlaylists) { playlist in
                NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                    resultRow(symbol: "square.stack.fill", color: playlist.coverColors.first ?? .gray, title: playlist.name, subtitle: "\(playlist.episodeIDs.count) episodes")
                }
            }
            resultSection("Topics", matchedTopics) { topic in
                let showIDs = Set(library.shows.filter { $0.topicIDs.contains(topic.id) }.map(\.id))
                NavigationLink {
                    EpisodeListView(title: topic.name, episodes: library.episodes.filter { showIDs.contains($0.showID) })
                } label: {
                    resultRow(symbol: "number", color: topic.color, title: topic.name, subtitle: nil)
                }
            }
            resultSection("Episodes", matchedEpisodes) { episode in
                Button {
                    playback.play(episode, queue: matchedEpisodes)
                } label: {
                    EpisodeRow(episode: episode)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func resultSection<Item: Identifiable, RowContent: View>(
        _ title: String, _ items: [Item], @ViewBuilder row: @escaping (Item) -> RowContent
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func resultRow(symbol: String, color: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.gradient)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: symbol).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        shelf(title, trailing: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func shelf<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                trailing()
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    content()
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct PlaylistCard: View {
    let playlist: PlaylistUI
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: playlist.coverColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: "square.stack.fill").font(.largeTitle).foregroundStyle(.white) }
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(playlist.episodeIDs.count, format: .number.grouping(.never)) episodes").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }
}

private struct AlbumCard: View {
    let album: PodcastAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(album.artColor.gradient)
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: album.symbol).font(.largeTitle).foregroundStyle(.white) }
            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(album.episodeIDs.count, format: .number.grouping(.never)) episodes").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }
}

private struct ShowCard: View {
    let show: PodcastShow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(show.artColor.gradient)
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: show.symbol).font(.largeTitle).foregroundStyle(.white) }
            Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(show.year, format: .number.grouping(.never))").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }
}

private struct SpeakerCard: View {
    let speaker: Speaker
    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 90, height: 90)
                .overlay { Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
            Text(speaker.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 90)
    }
}

private struct EpisodeCard: View {
    @EnvironmentObject private var library: MockLibraryStore
    @EnvironmentObject private var playback: PlaybackMockState
    let episode: PodcastEpisode
    var body: some View {
        Button {
            playback.play(episode, queue: library.episodes(forShow: episode.showID))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 10)
                    .fill((library.show(episode.showID)?.artColor ?? .gray).gradient)
                    .frame(width: 160, height: 90)
                    .overlay { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white) }
                Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(library.show(episode.showID)?.title ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
    }
}

private struct ChipCard: View {
    let title: String
    let color: Color
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
