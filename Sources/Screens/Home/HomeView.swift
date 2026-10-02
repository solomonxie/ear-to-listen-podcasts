import SwiftUI

/// Single-page root: search up top, then Home/Library shelves, and a Settings button at
/// the very bottom that opens sources and settings on a page of their own.
struct HomeView: View {
    @StateObject private var homeData = HomeLibraryViewModel()
    @StateObject private var settings = SettingsViewModel()

    @State private var query = ""
    /// Naming a new playlist happens in a row under the shelf rather than in an alert —
    /// an alert covers the shelf you're adding to, and costs a Cancel and a Create to
    /// type one word.
    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var editingBookmark: Bookmark?
    @State private var addingYouTubeLink: YouTubeLink?
    @State private var results = LibrarySearch.Results()
    /// Kept apart from `results`: this half is a database scan, so it lands after the
    /// in-memory one rather than holding it up.
    @State private var transcriptMatches: [TranscriptSearch.Match] = []

    private static let topAnchor = "home.top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy, not eager: a search that matches a few hundred episodes used to build
                // and lay out every row before the first one appeared on screen.
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !query.isEmpty {
                        searchResults
                    } else {
                        homeShelves
                        NavigationLink(value: HomeRoute.settings) {
                            Label("Settings", systemImage: "gearshape")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .id(Self.topAnchor)
            }
            // The mini bar's Top, pressed over Home.
            .onReceive(NotificationCenter.default.publisher(for: .homeScrollToTop)) { _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        // Registered once for the whole stack, so a page pushed from a pushed page —
        // a term reached from the Terms list — routes the same way.
        .navigationDestination(for: HomeRoute.self) { destination($0) }
        .navigationTitle("Good listening")
        .sheet(item: $addingYouTubeLink) { AddYouTubeEpisodeView(link: $0.link) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your podcasts")
        .onSubmit(of: .search) {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // Debounced: `.task(id:)` cancels the previous run on the next keystroke, so
        // holding a key down searches once at the end rather than once per character.
        .task(id: query) {
            guard !query.isEmpty else {
                results = LibrarySearch.Results()
                transcriptMatches = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            results = await LibrarySearch.run(query, in: homeData.searchIndex)
            transcriptMatches = await homeData.transcriptMatches(for: query)
        }
        .task { await homeData.refresh() }
        .onChange(of: PlaybackEngine.shared.isPresentingPlayer) { _, isShowing in
            if !isShowing { Task { await homeData.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            homeData.refreshSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
            homeData.refreshBookmarks()
        }
        .fullScreenCover(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark, episodeTitle: homeData.track(id: bookmark.trackID)?.title)
        }
    }

    /// Looked up when the page opens rather than captured by the card that opened it —
    /// which is the whole point of `HomeRoute`. Something deleted while its page is open
    /// leaves an empty page rather than a stale one.
    @ViewBuilder
    private func destination(_ route: HomeRoute) -> some View {
        switch route {
        case .album(let id):
            if let album = homeData.albums.first(where: { $0.id == id }) {
                AlbumDetailView(album: album)
            }
        case .speaker(let id):
            if let speaker = homeData.artists.first(where: { $0.id == id }) {
                SpeakerDetailView(speaker: speaker)
            }
        case .playlist(let id):
            if let playlist = homeData.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(playlist: playlist)
            }
        case .fixedPlaylist(let kind):
            FixedPlaylistView(kind: kind)
        case .year(let year):
            EpisodeListView(title: "\(year)", tracks: homeData.tracks(forYear: year))
        case .term(let id):
            if let term = homeData.terms.first(where: { $0.id == id })?.term {
                TermDetailView(term: term)
            }
        case .settings:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    SourcesSectionView(viewModel: settings)
                    Divider().padding(.horizontal)
                    SettingsSectionView(viewModel: settings)
                }
                .padding(.vertical)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { settings.load() }
        case .allTerms:
            TermsPageView(terms: homeData.terms)
        case .topic(let id):
            if let topic = homeData.topics.first(where: { $0.id == id }) {
                EpisodeListView(title: topic.name, tracks: homeData.tracks(forTopic: topic.id))
            }
        }
    }

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        homeData.createPlaylist(name: name)
        newPlaylistName = ""
        withAnimation(.easeOut(duration: 0.18)) { isNamingPlaylist = false }
    }

    private func play(_ track: Track, queue: [Track]) {
        PlaybackEngine.shared.open(track: track, queue: queue)
    }

    @ViewBuilder
    private var homeShelves: some View {
        if !homeData.recentTracks.isEmpty {
            shelf("Continue Listening") {
                ForEach(homeData.recentTracks) { track in
                    // Just the episode: the engine queues its collection in episode order. The
                    // shelf itself is a mix of shows, and Up Next is about track order.
                    TrackCard(track: track) { play(track, queue: [track]) }
                }
            }
        }

        if !homeData.artists.isEmpty {
            shelf("Speakers") {
                ForEach(homeData.artists) { artist in
                    NavigationLink(value: HomeRoute.speaker(artist.id)) {
                        SpeakerCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // Always shown — the two fixed playlists are always in it, and a listener with
        // nothing favourited still needs to be told where favourites will turn up.
        shelf("Playlists", trailing: {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isNamingPlaylist.toggle()
                }
            } label: {
                Image(systemName: isNamingPlaylist ? "xmark.circle.fill" : "plus.circle.fill")
            }
        }) {
            ForEach(FixedPlaylist.shown) { kind in
                NavigationLink(value: HomeRoute.fixedPlaylist(kind)) {
                    FixedPlaylistCard(kind: kind, count: homeData.count(of: kind))
                }
                .buttonStyle(.plain)
            }
            ForEach(homeData.playlists) { playlist in
                NavigationLink(value: HomeRoute.playlist(playlist.id)) {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
            }
        }

        // The name field unfolds under the shelf it adds to, rather than an alert over it.
        if isNamingPlaylist {
            HStack {
                TextField("Playlist name", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(createPlaylist)
                Button("Create", action: createPlaylist)
                    .buttonStyle(.borderedProminent)
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }

        // Below the playlists, as the marks you made inside episodes rather than a
        // collection of episodes in their own right.
        if !homeData.bookmarkGroups.isEmpty {
            BookmarksSection(
                groups: homeData.bookmarkGroups,
                onPlay: { track, bookmark in
                    PlaybackEngine.shared.open(track: track, queue: [track], startingAt: bookmark.position)
                },
                onEdit: { editingBookmark = $0 }
            )
        }

        // Under the marks: both are "where was I", this one for everything played.
        if !homeData.history.isEmpty {
            ListenHistorySection(tracks: homeData.history)
        }

        if !homeData.years.isEmpty {
            shelf("Browse by Year") {
                ForEach(homeData.years, id: \.self) { year in
                    NavigationLink(value: HomeRoute.year(year)) {
                        ChipCard(title: "\(year)", color: .gray)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // Chips like every other shelf, because that's what a shelf is here — the
        // counting is what makes terms different, and the place to *show* a count is a
        // page with room for a chart, not a row of capsules.
        if !homeData.terms.isEmpty {
            shelf("Terms", trailing: {
                NavigationLink(value: HomeRoute.allTerms) {
                    Text("More").font(.footnote)
                }
            }) {
                ForEach(homeData.terms.prefix(24)) { term in
                    NavigationLink(value: HomeRoute.term(term.id)) {
                        ChipCard(title: term.name, color: LibraryArt.color(for: term.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !homeData.topics.isEmpty {
            shelf("Topics") {
                ForEach(homeData.topics) { topic in
                    NavigationLink(value: HomeRoute.topic(topic.id)) {
                        ChipCard(title: topic.name, color: LibraryArt.color(for: topic.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        // A YouTube link pasted into search is a video to add, not words to look for.
        // Not on the China storefront, which YouTube doesn't reach.
        if !AppStorefront.isChina, YouTubeVideo.id(from: query) != nil {
            Button { addingYouTubeLink = YouTubeLink(link: query) } label: {
                resultRow(symbol: "play.rectangle.fill", color: .red, title: String(localized: "Add YouTube video"), subtitle: query)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 40)
        } else {
            resultSection("Speakers", results.speakers) { speaker in
                NavigationLink(value: HomeRoute.speaker(speaker.id)) {
                    HStack(spacing: 12) {
                        SpeakerAvatar(artist: speaker, size: 44)
                        Text(speaker.name).font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
                }
            }
            resultSection("Albums", results.albums) { album in
                NavigationLink(value: HomeRoute.album(album.id)) {
                    resultRow(symbol: "square.stack.fill", color: LibraryArt.color(for: album.id), title: album.name, subtitle: nil)
                }
            }
            resultSection("Playlists", results.playlists) { playlist in
                NavigationLink(value: HomeRoute.playlist(playlist.id)) {
                    resultRow(symbol: "square.stack.fill", color: LibraryArt.color(for: playlist.id), title: playlist.name, subtitle: nil)
                }
            }
            resultSection("Topics", results.topics) { topic in
                NavigationLink(value: HomeRoute.topic(topic.id)) {
                    resultRow(symbol: "number", color: LibraryArt.color(for: topic.id), title: topic.name, subtitle: nil)
                }
            }
            resultSection(episodesTitle, results.tracks) { track in
                Button { play(track, queue: [track]) } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
            }
            resultSection("Notes", results.notes) { bookmark in
                Button { play(bookmark) } label: {
                    BookmarkRow(
                        bookmark: bookmark,
                        episodeTitle: homeData.track(id: bookmark.trackID)?.title,
                        onPlay: { play(bookmark) },
                        onEdit: { editingBookmark = bookmark }
                    )
                }
                .buttonStyle(.plain)
            }
            // Last, and on purpose: names are what you search when you know what you're
            // after, speech is what you search when you don't. A line from the middle of
            // an episode outranking the episode you actually named would be wrong every
            // time.
            resultSection(transcriptsTitle, transcriptMatches) { match in
                Button { play(match) } label: {
                    TranscriptMatchRow(
                        match: match, episodeTitle: homeData.track(id: match.trackID)?.title
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transcriptsTitle: LocalizedStringKey {
        transcriptMatches.count >= TranscriptSearch.matchLimit
            ? "In transcripts (first \(TranscriptSearch.matchLimit))"
            : "In transcripts"
    }

    private func play(_ bookmark: Bookmark) {
        guard let track = homeData.track(id: bookmark.trackID) else { return }
        PlaybackEngine.shared.open(track: track, queue: [track], startingAt: bookmark.position)
    }

    private func play(_ match: TranscriptSearch.Match) {
        guard let track = homeData.track(id: match.trackID) else { return }
        PlaybackEngine.shared.open(track: track, queue: [track], startingAt: match.start)
    }

    /// Says so when the list is capped, rather than silently showing part of the answer.
    private var episodesTitle: LocalizedStringKey {
        results.totalTrackMatches > results.tracks.count
            ? "Episodes (first \(results.tracks.count) of \(results.totalTrackMatches))"
            : "Episodes"
    }

    @ViewBuilder
    private func resultSection<Item: Identifiable, RowContent: View>(
        _ title: LocalizedStringKey, _ items: [Item], @ViewBuilder row: @escaping (Item) -> RowContent
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).padding(.horizontal)
                LazyVStack(spacing: 0) {
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
            GeneratedCover(seed: playlist.id, title: playlist.name, kind: .playlist)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 120)
    }
}

private struct SpeakerCard: View {
    let artist: Artist
    var body: some View {
        VStack(spacing: 6) {
            SpeakerAvatar(artist: artist)
            Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(width: 90)
    }
}

/// A line of speech in the results: what was said, then which episode and when. The
/// episode comes second because the words are what matched — reading the title first
/// means reading past the answer to get to it.
private struct TranscriptMatchRow: View {
    let match: TranscriptSearch.Match
    let episodeTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(match.text).font(.footnote).lineLimit(3)
            HStack(spacing: 6) {
                Text(SeekBar.formatted(match.start)).monospacedDigit()
                if let episodeTitle {
                    Text("· \(episodeTitle)").lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct TrackCard: View {
    let track: Track
    let action: () -> Void
    private var isListened: Bool { track.listenedAt != nil }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkTile(track: track, album: LibraryNames.shared.album(track.albumID), symbolSize: 34)
                    .frame(width: 160, height: 90)
                    .opacity(isListened ? 0.5 : 1)
                    .overlay(alignment: .topTrailing) {
                        if isListened {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white, .green)
                                .padding(6)
                                .accessibilityLabel("Listened")
                        }
                    }
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(isListened ? .secondary : .primary)
                // Same reason as `TrackRow`'s: the title alone can be shared by a whole
                // folder of files. Which collection and whose voice says it better than a
                // filename, and is the thing a shelf card is short of room to say twice.
                Text(LibraryNames.shared.subtitle(for: track) ?? TrackRow.fileName(for: track))
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

struct YouTubeLink: Identifiable {
    let link: String
    var id: String { link }
}
