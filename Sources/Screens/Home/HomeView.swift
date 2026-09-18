import SwiftUI

/// Single-page root: search up top, then Home/Library shelves, then Remote and
/// Settings sections — no tab bar, everything reachable by scrolling.
struct HomeView: View {
    @StateObject private var homeData = HomeLibraryViewModel()
    @StateObject private var settings = SettingsViewModel()

    @State private var query = ""
    @State private var showingCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var showingDownloads = false
    @State private var editingBookmark: Bookmark?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !query.isEmpty {
                    searchResults
                } else if homeData.isEmpty {
                    emptyLibrary
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
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Good listening")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your podcasts")
        .onAppear { settings.load() }
        .task { await homeData.refresh() }
        .onChange(of: PlaybackEngine.shared.isPresentingPlayer) { _, isShowing in
            if !isShowing { Task { await homeData.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await homeData.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
            homeData.refreshBookmarks()
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark, episodeTitle: homeData.track(id: bookmark.trackID)?.title)
        }
        .sheet(isPresented: $showingDownloads) {
            NavigationStack { DownloadsView() }
        }
        .alert("New Playlist", isPresented: $showingCreatePlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                guard !newPlaylistName.isEmpty else { return }
                homeData.createPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func play(_ track: Track, queue: [Track]) {
        PlaybackEngine.shared.open(track: track, queue: queue)
    }

    /// A fresh install starts empty on purpose: sample content sitting in the same
    /// shelves as synced content is indistinguishable from it, so it's offered rather
    /// than assumed.
    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Nothing in your library yet", systemImage: "square.stack.3d.up.slash")
        } description: {
            Text("Connect an S3 bucket, or import episodes from Files below, and they appear here as they sync.")
        } actions: {
            Button("Load sample library") {
                try? DemoDataSeeder.load()
            }
            .buttonStyle(.bordered)
        }
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private var homeShelves: some View {
        shelf("Continue Listening") {
            ForEach(homeData.recentTracks) { track in
                TrackCard(track: track) { play(track, queue: homeData.recentTracks) }
            }
        }

        // Both shelves are hand-made marks rather than anything derived, so they sit
        // near the top where what you chose is what you see first.
        if !homeData.favoriteTracks.isEmpty {
            shelf("Favorites") {
                ForEach(homeData.favoriteTracks) { track in
                    TrackCard(track: track) { play(track, queue: homeData.favoriteTracks) }
                }
            }
        }

        if !homeData.bookmarks.isEmpty {
            shelf("Bookmarks") {
                ForEach(homeData.bookmarks) { bookmark in
                    if let track = homeData.track(id: bookmark.trackID) {
                        BookmarkCard(bookmark: bookmark, episodeTitle: track.title) {
                            PlaybackEngine.shared.open(track: track, queue: [track], startingAt: bookmark.position)
                        }
                        .contextMenu {
                            Button("Edit Bookmark…", systemImage: "square.and.pencil") { editingBookmark = bookmark }
                        }
                    }
                }
            }
        }

        shelf("Albums") {
            ForEach(homeData.albums) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Speakers") {
            ForEach(homeData.artists) { artist in
                NavigationLink { SpeakerDetailView(speaker: artist) } label: {
                    SpeakerCard(artist: artist)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Playlists", trailing: {
            Button { showingCreatePlaylist = true } label: { Image(systemName: "plus.circle.fill") }
        }) {
            ForEach(homeData.playlists) { playlist in
                NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Saved Shows") {
            ForEach(homeData.favoriteShows()) { show in
                NavigationLink { ShowDetailView(show: show) } label: {
                    ShowCard(show: show)
                }
                .buttonStyle(.plain)
            }
        }

        // The shelf shows what's downloaded; "More" is where you manage it — the full
        // list, with the sizes and the way to free the space up again.
        shelf("Downloaded", trailing: {
            Button("More") { showingDownloads = true }
                .font(.subheadline)
        }) {
            ForEach(homeData.downloadedTracks) { track in
                TrackCard(track: track) { play(track, queue: homeData.downloadedTracks) }
            }
        }

        shelf("Browse by Year") {
            ForEach(homeData.years, id: \.self) { year in
                NavigationLink {
                    EpisodeListView(title: "\(year)", tracks: homeData.tracks(forYear: year))
                } label: {
                    ChipCard(title: "\(year)", color: .gray)
                }
                .buttonStyle(.plain)
            }
        }

        shelf("Topics") {
            ForEach(homeData.topics) { topic in
                NavigationLink {
                    EpisodeListView(title: topic.name, tracks: homeData.tracks(forTopic: topic.id))
                } label: {
                    ChipCard(title: topic.name, color: LibraryArt.color(for: topic.id))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var matchedShows: [Show] { homeData.shows.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedSpeakers: [Artist] { homeData.artists.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedAlbums: [Album] { homeData.albums.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedPlaylists: [Playlist] { homeData.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    private var matchedTopics: [Topic] { homeData.topics.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    /// Path as well as title: with a folder of files sharing one embedded title tag, the
    /// filename is often the only thing the listener can actually search for.
    private var matchedTracks: [Track] {
        homeData.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.filePath.localizedCaseInsensitiveContains(query)
        }
    }
    private var hasResults: Bool {
        !(matchedShows.isEmpty && matchedSpeakers.isEmpty && matchedAlbums.isEmpty && matchedPlaylists.isEmpty && matchedTracks.isEmpty && matchedTopics.isEmpty)
    }

    @ViewBuilder
    private var searchResults: some View {
        if !hasResults {
            ContentUnavailableView.search(text: query)
                .padding(.top, 40)
        } else {
            resultSection("Shows", matchedShows) { show in
                NavigationLink { ShowDetailView(show: show) } label: {
                    resultRow(symbol: "mic.fill", color: LibraryArt.color(for: show.id), title: show.name, subtitle: nil)
                }
            }
            resultSection("Speakers", matchedSpeakers) { speaker in
                NavigationLink { SpeakerDetailView(speaker: speaker) } label: {
                    resultRow(symbol: "person.fill", color: .gray, title: speaker.name, subtitle: nil)
                }
            }
            resultSection("Albums", matchedAlbums) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    resultRow(symbol: "square.stack.fill", color: LibraryArt.color(for: album.id), title: album.name, subtitle: nil)
                }
            }
            resultSection("Playlists", matchedPlaylists) { playlist in
                NavigationLink { PlaylistDetailView(playlist: playlist) } label: {
                    resultRow(symbol: "square.stack.fill", color: LibraryArt.color(for: playlist.id), title: playlist.name, subtitle: nil)
                }
            }
            resultSection("Topics", matchedTopics) { topic in
                NavigationLink {
                    EpisodeListView(title: topic.name, tracks: homeData.tracks(forTopic: topic.id))
                } label: {
                    resultRow(symbol: "number", color: LibraryArt.color(for: topic.id), title: topic.name, subtitle: nil)
                }
            }
            resultSection("Episodes", matchedTracks) { track in
                Button { play(track, queue: matchedTracks) } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func resultSection<Item: Identifiable, RowContent: View>(
        _ title: LocalizedStringKey, _ items: [Item], @ViewBuilder row: @escaping (Item) -> RowContent
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
    private func shelf<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        shelf(title, trailing: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func shelf<Content: View, Trailing: View>(
        _ title: LocalizedStringKey,
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
    let playlist: Playlist
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LibraryArt.color(for: playlist.id).gradient)
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: "square.stack.fill").font(.largeTitle).foregroundStyle(.white) }
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 120)
    }
}

private struct AlbumCard: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LibraryArt.color(for: album.id).gradient)
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: "square.stack.fill").font(.largeTitle).foregroundStyle(.white) }
            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 120)
    }
}

private struct ShowCard: View {
    let show: Show
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LibraryArt.color(for: show.id).gradient)
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: "mic.fill").font(.largeTitle).foregroundStyle(.white) }
            Text(show.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 120)
    }
}

private struct SpeakerCard: View {
    let artist: Artist
    var body: some View {
        VStack(spacing: 6) {
            SpeakerAvatar(photoFileName: artist.photoFileName)
            Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 90)
    }
}

private struct TrackCard: View {
    let track: Track
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkTile(track: track, symbolSize: 34)
                    .frame(width: 160, height: 90)
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                // Same reason as `TrackRow`'s: the title alone can be shared by a whole
                // folder of files.
                Text(TrackRow.fileName(for: track))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let positionMs = track.positionMs, let durationMs = track.durationMs, durationMs > 0 {
                    ProgressView(value: Double(positionMs), total: Double(durationMs))
                }
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
