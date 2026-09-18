import PhotosUI
import SwiftUI

/// Edit everything an episode shows — artwork, title, speaker, album, show, year, track
/// number, notes. Embedded tags are only a starting point: a batch export routinely
/// stamps a whole folder with one generic title, and nothing but the file path tells
/// those apart. Saved edits stand: sync only reads tags for files the library doesn't
/// know yet, so nothing overwrites them later.
struct EpisodeEditView: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artistName: String
    @State private var albumName: String
    @State private var showName: String
    @State private var year: String
    @State private var trackNumber: String
    @State private var notes: String
    @State private var artworkFileName: String?
    @State private var artworkImage: UIImage?
    @State private var artworkItem: PhotosPickerItem?
    @State private var language: String?
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    @State private var readiness: EpisodeMetadataSuggester.Readiness = .noTranscript

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(track: Track) {
        self.track = track
        let store = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
        _title = State(initialValue: track.title)
        _artistName = State(initialValue: (track.artistID.flatMap { try? store.artist(id: $0) } ?? nil)?.name ?? "")
        _albumName = State(initialValue: (track.albumID.flatMap { try? store.album(id: $0) } ?? nil)?.name ?? "")
        _showName = State(initialValue: (track.showID.flatMap { try? store.show(id: $0) } ?? nil)?.name ?? "")
        _year = State(initialValue: track.year.map(String.init) ?? "")
        _trackNumber = State(initialValue: track.trackNumber.map(String.init) ?? "")
        _notes = State(initialValue: track.notes ?? "")
        _artworkFileName = State(initialValue: track.artworkFileName)
        _language = State(initialValue: track.language)
    }

    /// What this episode would transcribe in without an answer of its own — its album's
    /// language, then its speaker's, then nothing at all.
    private var inheritedLanguageLabel: String {
        let store = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
        if let albumID = track.albumID, let language = (try? store.album(id: albumID))??.language {
            return TranscriptPane.languageName(Locale(identifier: language))
        }
        if let artistID = track.artistID, let language = (try? store.artist(id: artistID))??.language {
            return TranscriptPane.languageName(Locale(identifier: language))
        }
        return "automatic"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Captured by value rather than read inside the closure — `PhotosPicker`'s
                    // label closure is `@Sendable`, so it can't touch this main-actor state,
                    // which is also why the preview holds no state of its own.
                    let preview = artworkImage
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            PhotosPicker(selection: $artworkItem, matching: .images) {
                                ArtworkPreview(image: preview, seed: track.id)
                            }
                            if artworkFileName != nil {
                                Button("Remove Artwork", role: .destructive) { removeArtwork() }
                                    .font(.footnote)
                            }
                        }
                        Spacer()
                    }
                }
                .listRowSeparator(.hidden)

                Section("Episode") {
                    TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
                    TextField("Speaker", text: $artistName)
                    TextField("Album", text: $albumName)
                    TextField("Show", text: $showName)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Track no.", text: $trackNumber).keyboardType(.numberPad)
                    // The last word on which recognizer to use: this is the one level
                    // where someone has actually heard the audio.
                    SpokenLanguagePicker(
                        title: "Language", inheritedLabel: inheritedLanguageLabel, language: $language
                    )
                }

                Section("Notes") {
                    TextField("What this episode is about", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Button {
                        Task { await suggest() }
                    } label: {
                        HStack {
                            Label("Suggest with AI", systemImage: "sparkles")
                            Spacer()
                            if isSuggesting { ProgressView() }
                        }
                    }
                    .disabled(isSuggesting || !readiness.isReady)
                    if let blockedReason = readiness.blockedReason {
                        Text(blockedReason).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let suggestionError {
                        Text(suggestionError).font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Reads this episode's transcript — the whole of it, which is why it waits for transcribing to finish. Fills the fields in above; nothing is saved until you tap Save.")
                }

                Section("File") {
                    Text(track.filePath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: artworkItem) { _, newItem in
                Task { await handlePick(newItem) }
            }
            .task(id: artworkFileName) { loadArtwork() }
            // Re-checked on every appearance: the transcript may have finished filling in
            // since the last time this sheet was open.
            .task { readiness = EpisodeMetadataSuggester().readiness(track: track) }
        }
    }

    private func suggest() async {
        isSuggesting = true
        suggestionError = nil
        do {
            let suggestion = try await EpisodeMetadataSuggester().suggest(
                track: track, title: title, artist: artistName, album: albumName, show: showName, notes: notes
            )
            // Only fills what the model actually improved on — a null field leaves
            // whatever's in the form alone rather than blanking it.
            if let suggested = suggestion.title { title = suggested }
            if let suggested = suggestion.artist { artistName = suggested }
            if let suggested = suggestion.album { albumName = suggested }
            if let suggested = suggestion.show { showName = suggested }
            if let suggested = suggestion.year { year = String(suggested) }
            if let suggested = suggestion.notes { notes = suggested }
        } catch {
            suggestionError = error.localizedDescription
        }
        isSuggesting = false
    }

    private func loadArtwork() {
        guard let url = ImageFileStore.artwork.url(for: artworkFileName), let data = try? Data(contentsOf: url) else {
            artworkImage = nil
            return
        }
        artworkImage = UIImage(data: data)
    }

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item, let picked = try? await item.loadTransferable(type: PickedImageFile.self) else { return }
        defer { picked.discard() }
        guard let newFileName = try? await ImageFileStore.artwork.save(contentsOf: picked.url, maxDimension: 800) else { return }
        // Drop artwork picked earlier in this same session but never committed via Save.
        discardIfUncommitted(artworkFileName)
        artworkFileName = newFileName
    }

    private func removeArtwork() {
        discardIfUncommitted(artworkFileName)
        artworkFileName = nil
    }

    private func cancel() {
        discardIfUncommitted(artworkFileName)
        dismiss()
    }

    private func discardIfUncommitted(_ fileName: String?) {
        guard fileName != track.artworkFileName else { return }
        ImageFileStore.artwork.remove(fileName)
    }

    private func save() {
        try? trackStore.setLanguage(id: track.id, language: language)
        let artist = trimmed(artistName).flatMap { try? libraryStore.upsertArtist(name: $0) }
        let album = trimmed(albumName).flatMap { name in try? libraryStore.upsertAlbum(name: name, artistID: artist?.id) }
        let show = trimmed(showName).flatMap { try? libraryStore.upsertShow(name: $0) }

        var updated = track
        updated.title = trimmed(title) ?? TrackRow.fileName(for: track)
        updated.artistID = artist?.id
        updated.albumID = album?.id
        updated.showID = show?.id
        updated.year = trimmed(year).flatMap { Int($0) }
        updated.trackNumber = trimmed(trackNumber).flatMap { Int($0) }
        updated.notes = trimmed(notes)
        updated.artworkFileName = artworkFileName
        updated.metadataEditedAt = Date()
        try? trackStore.upsert(updated, artistName: artist?.name, albumName: album?.name)

        if artworkFileName != track.artworkFileName {
            ImageFileStore.artwork.remove(track.artworkFileName)
        }
        // Home and the player hold their own copies of these rows, so they need telling —
        // otherwise the edit only lands after some unrelated refresh.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        dismiss()
    }

    private func trimmed(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

/// A standalone, stateless view (rather than a computed property) so `PhotosPicker`'s
/// label closure doesn't capture `EpisodeEditView`'s `self` across an actor boundary.
private struct ArtworkPreview: View {
    let image: UIImage?
    let seed: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(LibraryArt.color(for: seed).gradient)
                    .overlay { Image(systemName: LibraryArt.symbol(for: seed)).font(.system(size: 36)).foregroundStyle(.white) }
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption)
                .padding(6)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}
