import PhotosUI
import SwiftUI

/// A collection's own page: its picture and name, then what it is, then the episodes.
///
/// **Details are edited in place.** Speaker, year, language and notes are ordinary form
/// rows — label left, value right, tap the value and type — and each commits when it
/// loses focus. An Edit button leading to a second copy of the same page is a screen
/// transition, a form to re-read and a Save to remember, for changing one word that is
/// already on screen.
///
/// Three glyphs, three meanings, never mixed: a plain value is typeable, `⌄` is a
/// picker, and `›` goes somewhere — which is why opening the speaker's page is its own
/// row rather than a chevron sharing a row with the speaker field.
struct AlbumDetailView: View {
    let album: Album
    @State private var current: Album?
    @State private var tracks: [Track] = []
    @State private var artistName: String?
    @State private var downloadedCount = 0
    @State private var transcribedCount = 0
    @State private var showingAnalysis = false
    @State private var topicNames = ""
    @State private var suggestions = ProfileSuggestionState()
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    /// Which unfolding picker is open — one at a time, across the whole form.
    @State private var openPicker: String?
    @State private var allSpeakers: [Artist] = []
    @State private var bookmarks: [Bookmark] = []
    @State private var editingBookmark: Bookmark?
    @State private var artworkItem: PhotosPickerItem?
    /// The live fields. Seeded from the album, and left alone while a field has the
    /// keyboard — a sync landing mid-edit must not retype what's being typed.
    @State private var name = ""
    @State private var speakerName = ""
    @State private var year = ""
    @State private var notes = ""
    @State private var profile = ""
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
                // Picked, not typed: a speaker already exists as a row with a page of
                // their own, and typing their name again by hand is how you end up with
                // two of them differing by a space.
                UnfoldingPicker(
                    title: "Speaker", id: "speaker", open: $openPicker, selection: $speakerName,
                    options: [UnfoldingPicker.Option("", "None")]
                        + allSpeakers.map { UnfoldingPicker.Option($0.name, $0.name) }
                )
                // The album's own year, and what every episode in it falls back to.
                UnfoldingWheel(
                    title: "Year", id: "year", open: $openPicker, value: yearValue,
                    choices: NumberChoices.years
                )
                rejectNote("year")
                SpokenLanguagePicker(
                    title: "Language", inheritedLabel: speakerLanguageLabel, language: $language,
                    id: "language", open: $openPicker
                )
                TagField(
                    names: topicNames.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    open: $openPicker,
                    onChange: { names in
                        topicNames = names.joined(separator: ", ")
                        save()
                    }
                )
                rejectNote("topics")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Full width rather than a right-hand column: a sentence about what
                    // this collection is needs the room, and wraps badly without it.
                    TextField("What this collection is", text: $notes, axis: .vertical)
                        .lineLimit(1...)
                        .focused($focusedField, equals: .notes)
                }
                rejectNote("notes")
                // Its own row, because it's the one thing here that leaves the page.
                // Sharing the speaker field's row is what put two chevrons on it.
                if let speaker {
                    NavigationLink {
                        SpeakerDetailView(speaker: speaker)
                    } label: {
                        Label("Open \(speaker.name)'s page", systemImage: "person.crop.circle")
                    }
                }
            } header: {
                HStack {
                    Text("Details")
                    Spacer()
                    SuggestWithAiButton(isRunning: isSuggesting) { Task { await suggest() } }
                        .disabled(tracks.isEmpty)
                }
            } footer: {
                if let suggestionError {
                    Text(suggestionError).foregroundStyle(.orange)
                }
            }

            // Its own section rather than another row: it's paragraphs, and it's the
            // part of the page worth actually reading.
            Section("Profile") {
                TextField(
                    "What this collection is — or fill it in from ⋯ → Describe this collection",
                    text: $profile, axis: .vertical
                )
                .lineLimit(3...)
                .focused($focusedField, equals: .profile)
                rejectNote("profile")
            }

            Section("Stats") {
                LabeledContent("Episodes", value: "\(tracks.count)")
                if let totalDuration { LabeledContent("Total length", value: totalDuration) }
                if let years { LabeledContent("Episode years", value: years) }
                if let folder { LabeledContent("Folder", value: folder) }
                LabeledContent("Downloaded", value: "\(downloadedCount) of \(tracks.count)")
                // What the batch pass can actually read, stated before you open it.
                LabeledContent("Fully transcribed", value: "\(transcribedCount) of \(tracks.count)")
                if let size { LabeledContent("Size on storage", value: size) }
                if let edited = shown.metadataEditedAt {
                    LabeledContent("Edited", value: edited.formatted(date: .abbreviated, time: .shortened))
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
        // Leaving a field is the save, as everywhere else in the app: no Save button to
        // find, and nothing lost by scrolling away or closing the page.
        .onChange(of: focusedField) { previous, _ in
            guard previous != nil else { return }
            save()
        }
        .onChange(of: language) { _, _ in save() }
        .onChange(of: speakerName) { _, _ in save() }
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Reads finished transcripts to rewrite each episode's title. Saying
                    // what the *collection* is needs no transcript, so that lives as the
                    // ✨ button on the Details header rather than in here.
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

    /// Picture, name, size — and the one button anyone came here to press. The picture
    /// and the name are their own controls; everything else about the album is a form row
    /// below.
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
                .lineLimit(1...)
                .focused($focusedField, equals: .name)
                .submitLabel(.done)

            Text(metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)

        }
        .frame(maxWidth: .infinity)
        .task(id: artworkItem) { await handleArtworkPick() }
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
        profile = shown.profile ?? ""
        topicNames = ((try? libraryStore.topics(forAlbum: shown.id)) ?? []).map(\.name).joined(separator: ", ")
        language = shown.language
    }

    private var yearValue: Binding<Int?> {
        Binding(get: { Int(year) }, set: { year = $0.map(String.init) ?? "" })
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? libraryStore.updateAlbum(
            id: shown.id,
            name: trimmedName.nilIfEmpty ?? shown.name,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            artworkFileName: shown.artworkFileName,
            year: Int(year.trimmingCharacters(in: .whitespacesAndNewlines)),
            profile: .some(profile.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        )
        try? libraryStore.updateAlbumLanguage(id: shown.id, language: language)
        try? libraryStore.setTopics(topicNames.split(separator: ",").map(String.init), forAlbum: shown.id)
        // A wrong speaker here is wrong on every episode in the album, so it's written
        // through rather than left to be fixed forty more times. "None" is a real answer
        // and has to be written through too, not quietly ignored.
        let trimmedSpeaker = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSpeaker != (artistName ?? "") {
            if trimmedSpeaker.isEmpty {
                try? libraryStore.clearAlbumArtist(albumID: shown.id)
            } else {
                _ = try? libraryStore.reassignAlbumArtist(albumID: shown.id, artistName: trimmedSpeaker)
            }
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @ViewBuilder
    private func rejectNote(_ id: String) -> some View {
        if suggestions.wasSuggested(id) {
            SuggestedFieldNote { reject(id) }
        }
    }

    /// One tap: run it, write it into the fields, save. What came back is visible in the
    /// page itself and each field can be put back on its own — so there's nothing to
    /// confirm, and nothing is lost by trying it.
    private func suggest() async {
        isSuggesting = true
        suggestionError = nil
        defer { isSuggesting = false }
        do {
            let suggestion = try await AlbumProfileSuggester()
                .analyze(album: shown, artistName: artistName, tracks: tracks)
            guard !suggestion.isEmpty else {
                suggestionError = "Nothing to add — there wasn't enough here to go on."
                return
            }
            if let current = try? BackupService().currentArchive() {
                LocalBackups.writeBefore("album-profile", archive: current)
            }
            apply(suggestion.notes, id: "notes")
            apply(suggestion.profile, id: "profile")
            apply(suggestion.year.map(String.init), id: "year")
            apply(suggestion.topics.isEmpty ? nil : suggestion.topics.joined(separator: ", "), id: "topics")
            save()
        } catch {
            suggestionError = error.localizedDescription
        }
    }

    /// Writes one suggested field, remembering what it replaced. A nil means the pass had
    /// nothing to say about that field — which is a real answer, not a blank to write.
    private func apply(_ text: String?, id: String) {
        guard let text else { return }
        switch id {
        case "notes": suggestions.record(id, previous: notes); notes = text
        case "profile": suggestions.record(id, previous: profile); profile = text
        case "year": suggestions.record(id, previous: year); year = text
        case "topics": suggestions.record(id, previous: topicNames); topicNames = text
        default: return
        }
    }

    private func reject(_ id: String) {
        guard let previous = suggestions.reject(id) else { return }
        switch id {
        case "notes": notes = previous
        case "profile": profile = previous
        case "year": year = previous
        case "topics": topicNames = previous
        default: return
        }
        save()
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
        allSpeakers = (try? libraryStore.artists()) ?? []
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

private enum AlbumField: Hashable {
    case name, speaker, year, notes, profile, topics
}
