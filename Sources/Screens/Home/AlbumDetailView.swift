import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @State private var current: Album?
    @State private var tracks: [Track] = []
    @State private var artistName: String?
    @State private var downloadedCount = 0
    @State private var transcribedCount = 0
    @State private var showingEdit = false
    @State private var showingAnalysis = false
    @State private var bookmarks: [Bookmark] = []
    @State private var editingBookmark: Bookmark?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var shown: Album { current ?? album }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    ArtworkTile(album: shown)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                    HStack {
                        // Tappable rather than plain text — embedded/guessed speaker
                        // metadata is sometimes wrong (a shared uploader/collection name
                        // instead of the actual speaker), so it needs to be correctable.
                        Button { showingEdit = true } label: {
                            Text(artistName ?? "Set speaker")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(artistName == nil ? .secondary : .primary)
                        }
                        Spacer()
                        Text("\(tracks.count) episode\(tracks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let first = tracks.first {
                        Button {
                            PlaybackEngine.shared.open(track: first, queue: tracks)
                        } label: {
                            Label("Play latest", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .listRowSeparator(.hidden)
            }

            if let notes = shown.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                LabeledContent("Episodes", value: "\(tracks.count)")
                if let totalDuration { LabeledContent("Total length", value: totalDuration) }
                if let years { LabeledContent("Years", value: years) }
                if let folder { LabeledContent("Folder", value: folder) }
                LabeledContent("Downloaded", value: "\(downloadedCount) of \(tracks.count)")
                // What the batch pass can actually read, stated before you open it.
                LabeledContent("Fully transcribed", value: "\(transcribedCount) of \(tracks.count)")
                if let size { LabeledContent("Size on storage", value: size) }
                if let edited = shown.metadataEditedAt {
                    LabeledContent("Details edited", value: edited.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.footnote)

            // Above the episode list on purpose: a moment someone marked by hand is
            // worth more than the twentieth row of a folder listing.
            if !bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(bookmarks) { bookmark in
                        BookmarkRow(
                            bookmark: bookmark,
                            episodeTitle: tracks.first { $0.id == bookmark.trackID }?.title
                        ) {
                            play(bookmark)
                        } onEdit: {
                            editingBookmark = bookmark
                        }
                    }
                }
            }

            Section("Episodes") {
                ForEach(tracks) { track in
                    Button {
                        PlaybackEngine.shared.open(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit Album…", systemImage: "pencil") { showingEdit = true }
                    Button("Analyze with AI…", systemImage: "sparkles") { showingAnalysis = true }
                        .disabled(transcribedCount == 0)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark, episodeTitle: tracks.first { $0.id == bookmark.trackID }?.title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
            bookmarks = (try? bookmarkStore.all(forTracks: tracks.map(\.id))) ?? []
        }
        .sheet(isPresented: $showingEdit) { AlbumEditView(album: shown, artistName: artistName) }
        .sheet(isPresented: $showingAnalysis) {
            AlbumAnalysisView(album: shown, artistName: artistName, tracks: tracks)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await load() }
        }
    }

    /// Plays the episode the mark belongs to, from the mark — the album is the queue, so
    /// listening carries on from there.
    private func play(_ bookmark: Bookmark) {
        guard let track = tracks.first(where: { $0.id == bookmark.trackID }) else { return }
        PlaybackEngine.shared.open(track: track, queue: tracks, startingAt: bookmark.position)
    }

    private var totalDuration: String? {
        let ms = tracks.compactMap(\.durationMs).reduce(0, +)
        return ms > 0 ? TrackRow.formattedDuration(ms) : nil
    }

    private var years: String? {
        let values = Set(tracks.compactMap(\.year)).sorted()
        guard let first = values.first, let last = values.last else { return nil }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    private var size: String? {
        let bytes = tracks.compactMap(\.sizeBytes).reduce(Int64(0), +)
        return bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : nil
    }

    /// The deepest folder every episode shares — for a well-sorted bucket that's the
    /// album's own directory, and it's what tells two same-named collections apart.
    private var folder: String? {
        let folders = tracks.map { ($0.filePath as NSString).deletingLastPathComponent }
        guard let first = folders.first, !first.isEmpty, folders.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func load() async {
        current = (try? libraryStore.album(id: album.id)) ?? nil
        tracks = (try? trackStore.tracks(forAlbum: album.id)) ?? []
        artistName = (shown.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil)?.name
        transcribedCount = AlbumMetadataSuggester().partition(tracks: tracks).ready.count
        bookmarks = (try? bookmarkStore.all(forTracks: tracks.map(\.id))) ?? []
        var downloaded = 0
        for track in tracks where await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) != nil {
            downloaded += 1
        }
        downloadedCount = downloaded
    }
}
