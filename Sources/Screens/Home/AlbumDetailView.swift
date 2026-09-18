import PhotosUI
import SwiftUI

/// A collection's own page: its picture, its name, whose voice it is, and how much of it
/// there is — then the episodes. The header says the four things worth knowing at a
/// glance and nothing else; the counts and paths that used to sit between it and the
/// episode list are a row you can open, because they answer questions nobody asks twice.
///
/// **The header is the editor.** Everything in it is live — the picture, the name, the
/// speaker, the year, the language — and commits when it loses focus, the way an
/// episode's own card does. An Edit button leading to a second copy of the same page is a
/// screen transition, a form to re-read and a Save to remember, for changing one word
/// that is already on screen.
struct AlbumDetailView: View {
    let album: Album
    @State private var current: Album?
    @State private var tracks: [Track] = []
    @State private var artistName: String?
    @State private var downloadedCount = 0
    @State private var transcribedCount = 0
    @State private var showingAnalysis = false
    @State private var bookmarks: [Bookmark] = []
    @State private var editingBookmark: Bookmark?
    @State private var artworkItem: PhotosPickerItem?
    @State private var showingDetails = false
    /// The live fields. Seeded from the album, and left alone while a field has the
    /// keyboard — a sync landing mid-edit must not retype what's being typed.
    @State private var name = ""
    @State private var speakerName = ""
    @State private var year = ""
    @State private var notes = ""
    @State private var language: String?
    @FocusState private var focusedField: AlbumField?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var shown: Album { current ?? album }

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
            }

            Section {
                DisclosureGroup("Details", isExpanded: $showingDetails) {
                    LabeledContent("Episodes", value: "\(tracks.count)")
                    if let totalDuration { LabeledContent("Total length", value: totalDuration) }
                    if let years { LabeledContent("Episode years", value: years) }
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
            }

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
        .sheet(isPresented: $showingAnalysis) {
            AlbumAnalysisView(album: shown, artistName: artistName, tracks: tracks)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await load() }
        }
    }

    /// Picture, name, voice, size — and the one button anyone came here to press. Every
    /// one of them is the control for itself.
    private var header: some View {
        VStack(spacing: 12) {
            // The picture is the control: tapping it picks a new one, the way an episode's
            // own artwork works. Nobody should have to find an Edit sheet to fix a
            // collection whose cover came out of a stray MP3 tag.
            PhotosPicker(selection: $artworkItem, matching: .images) {
                ArtworkTile(album: shown)
                    .frame(width: 168, height: 168)
                    .shadow(radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if shown.artworkFileName != nil {
                    Button("Remove Picture", systemImage: "trash", role: .destructive) { removeArtwork() }
                }
            }

            TextField("Album name", text: $name, axis: .vertical)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1...3)
                .focused($focusedField, equals: .name)
                .submitLabel(.done)

            VStack(alignment: .leading, spacing: 10) {
                // Tappable rather than plain text — embedded speaker metadata is often a
                // shared uploader or collection name rather than who is actually speaking,
                // and changing it here re-points every episode in the album.
                AlbumFieldRow(label: "Speaker") {
                    HStack(spacing: 6) {
                        TextField("Who is speaking", text: $speakerName)
                            .focused($focusedField, equals: .speaker)
                            .submitLabel(.done)
                        if let artist = speaker {
                            NavigationLink {
                                SpeakerDetailView(speaker: artist)
                            } label: {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                AlbumFieldRow(label: "Year") {
                    // The album's own year, and what every episode in it falls back to.
                    TextField("—", text: $year)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .year)
                }
                AlbumFieldRow(label: "Language") {
                    SpokenLanguagePicker(
                        title: "", inheritedLabel: speakerLanguageLabel, language: $language
                    )
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                AlbumFieldRow(label: "Notes") {
                    TextField("What this collection is", text: $notes, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focusedField, equals: .notes)
                }
            }
            .font(.footnote)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Text(metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .frame(maxWidth: .infinity)
        .task(id: artworkItem) { await handleArtworkPick() }
        // Leaving a field is the save, as everywhere else in the app: no Save button to
        // find, and nothing lost by scrolling away or closing the page.
        .onChange(of: focusedField) { previous, _ in
            guard previous != nil else { return }
            save()
        }
        .onChange(of: language) { _, _ in save() }
    }

    private var speaker: Artist? {
        shown.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
    }

    /// What this album would transcribe in if its language stayed on "inherit".
    private var speakerLanguageLabel: String {
        guard let language = speaker?.language else { return "automatic" }
        return TranscriptPane.languageName(Locale(identifier: language))
    }

    /// Fills the fields from the album — but never over a field being typed into.
    private func seedFields() {
        guard focusedField == nil else { return }
        name = shown.name
        speakerName = artistName ?? ""
        year = shown.year.map(String.init) ?? ""
        notes = shown.notes ?? ""
        language = shown.language
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? libraryStore.updateAlbum(
            id: shown.id,
            name: trimmedName.nilIfEmpty ?? shown.name,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            artworkFileName: shown.artworkFileName,
            year: Int(year.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        try? libraryStore.updateAlbumLanguage(id: shown.id, language: language)
        let trimmedSpeaker = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSpeaker.isEmpty, trimmedSpeaker != artistName {
            // A wrong speaker here is wrong on every episode in the album, so it's
            // written through rather than left to be fixed forty more times.
            _ = try? libraryStore.reassignAlbumArtist(albumID: shown.id, artistName: trimmedSpeaker)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Year, count, length — skipping whichever of them this collection can't answer.
    private var metaLine: String {
        var parts: [String] = []
        if let year = shown.year { parts.append(String(year)) }
        parts.append("\(tracks.count) episode\(tracks.count == 1 ? "" : "s")")
        if let totalDuration { parts.append(totalDuration) }
        return parts.joined(separator: " · ")
    }

    private func handleArtworkPick() async {
        guard let artworkItem, let picked = try? await artworkItem.loadTransferable(type: PickedImageFile.self) else { return }
        defer { picked.discard() }
        guard let fileName = try? await ImageFileStore.artwork.save(contentsOf: picked.url, maxDimension: 800) else { return }
        let previous = shown.artworkFileName
        try? libraryStore.updateAlbum(
            id: shown.id, name: shown.name, notes: shown.notes, artworkFileName: fileName, year: shown.year
        )
        ImageFileStore.artwork.remove(previous)
        self.artworkItem = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func removeArtwork() {
        let previous = shown.artworkFileName
        try? libraryStore.updateAlbum(
            id: shown.id, name: shown.name, notes: shown.notes, artworkFileName: nil, year: shown.year
        )
        ImageFileStore.artwork.remove(previous)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
        seedFields()
    }
}

/// One editable row on the album header: the label column the rest of the app uses, and
/// whatever control belongs to that field beside it.
private struct AlbumFieldRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum AlbumField: Hashable {
    case name, speaker, year, notes
}
