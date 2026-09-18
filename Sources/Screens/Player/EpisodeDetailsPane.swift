import PhotosUI
import SwiftUI

/// Everything known about what's playing — the tags that came off the file, where the
/// file actually lives, and the dates that explain why it looks the way it does. Grouped
/// cards rather than one flat list, so "who/what" doesn't blur into "which file".
///
/// The Episode card is the editor too: every field is a live control, showing even when
/// empty, and a change lands as soon as you leave the field. Correcting a title is the
/// commonest thing anyone does here, and routing it through a modal cost a tap in, a tap
/// out and the scroll position of a long transcript.
struct EpisodeDetailsPane: View {
    let playingTrack: Track

    /// Re-read rather than taken from `PlaybackEngine`, whose copy was loaded before
    /// playback started — "Stopped at" would otherwise show where the last session ended.
    @State private var latest: Track?
    @State private var artist: Artist?
    @State private var album: Album?
    @State private var show: Show?
    @State private var topics: [Topic] = []
    @State private var connectionLabel: String?
    @State private var downloadedBytes: Int64?

    @State private var title = ""
    @State private var artistName = ""
    @State private var albumName = ""
    @State private var showName = ""
    @State private var year = ""
    @State private var trackNumber = ""
    @State private var notes = ""
    /// What the fields held the last time they matched the database — the test for
    /// "is there anything to save", without an `onChange` per field.
    @State private var savedSnapshot = ""
    /// Which track the fields are currently holding. Playback can move on mid-edit, and
    /// without this the half-typed year would be saved onto whatever came next.
    @State private var draftTrackID = ""
    @FocusState private var focusedField: EpisodeField?

    @State private var bookmarks: [Bookmark] = []
    @State private var editingBookmark: Bookmark?
    @State private var artworkItem: PhotosPickerItem?
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    @State private var readiness: EpisodeMetadataSuggester.Readiness = .noTranscript

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var track: Track { latest ?? playingTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if track.isLost {
                Label("Missing from the last sync — the file wasn't in the bucket listing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            DetailCard("Episode") { episodeFields }
            DetailCard("Notes") {
                TextField("What this episode is about", text: $notes, axis: .vertical)
                    .font(.footnote)
                    .lineLimit(2...8)
                    .focused($focusedField, equals: .notes)
            }

            if !bookmarks.isEmpty {
                DetailCard("Bookmarks") {
                    ForEach(bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark) {
                            PlaybackEngine.shared.seek(to: bookmark.position)
                        } onEdit: {
                            editingBookmark = bookmark
                        }
                        if bookmark.id != bookmarks.last?.id { Divider() }
                    }
                }
            }

            DetailCard("File") {
                DetailRow("Connection", connectionLabel)
                DetailRow("Folder", folder)
                DetailRow("File", (track.filePath as NSString).lastPathComponent)
                DetailRow("Format", fileExtension)
                DetailRow("Size", track.sizeBytes.map { $0.formatted(.byteCount(style: .file)) })
                DetailRow("Downloaded", downloadedBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "Not downloaded")
            }

            DetailCard("Dates") {
                DetailRow("Changed on storage", Self.formatted(track.remoteModifiedAt))
                DetailRow("Last synced", Self.formatted(track.updatedAt))
                DetailRow("Last played", Self.formatted(track.lastPlayedAt) ?? "Never")
                DetailRow("Details edited", Self.formatted(track.metadataEditedAt))
                DetailRow("Stopped at", track.positionMs.map { Scrubber.formatted(Double($0) / 1000) })
            }

            if let summary = show?.summary, !summary.isEmpty {
                DetailCard("About the show") {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .task(id: playingTrack.id) { await load() }
        .task(id: playingTrack.id) { readiness = EpisodeMetadataSuggester().readiness(track: track) }
        // Sync and the other editors hold their own copies of these rows; this is what
        // puts their changes on screen without waiting for the next track change.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
            bookmarks = (try? bookmarkStore.all(forTrack: track.id)) ?? []
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark)
        }
        // Leaving a field is the commit. Scrolling away, or the page closing, counts too.
        .onChange(of: focusedField) { previous, _ in
            if previous != nil { save() }
        }
        .onChange(of: artworkItem) { _, item in
            Task { await handleArtworkPick(item) }
        }
        .onDisappear { save() }
        // Nothing on this page is a form with a Save button, so the keyboard needs its own
        // way out — tapping the artwork or scrolling the page works too, but Done is the
        // one that's always in the same place.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    @ViewBuilder
    private var episodeFields: some View {
        TextField("Title", text: $title, axis: .vertical)
            .font(.footnote.weight(.medium))
            .lineLimit(1...3)
            .focused($focusedField, equals: .title)
            .submitLabel(.done)
            .onSubmit { focusedField = nil }

        EditableRow("Speaker", text: $artistName, field: .speaker, focus: $focusedField, link: artist.map(EpisodeLink.speaker))
        EditableRow("Album", text: $albumName, field: .album, focus: $focusedField, link: album.map(EpisodeLink.album))
        EditableRow("Show", text: $showName, field: .show, focus: $focusedField, link: show.map(EpisodeLink.show))
        EditableRow(
            "Year", text: $year, field: .year, focus: $focusedField, keyboard: .numberPad,
            placeholder: album?.year.map { "\($0) · from album" } ?? "—"
        )
        EditableRow("Track no.", text: $trackNumber, field: .trackNumber, focus: $focusedField, keyboard: .numberPad)

        // The one field that isn't the listener's own text: it's asked for here, where
        // the rest of the episode is described, and the transcript pane no longer asks.
        EpisodeLanguageRow()

        DetailRow("Duration", track.durationMs.map(TrackRow.formattedDuration))
        if !topics.isEmpty {
            TagRow(names: topics.map(\.name))
        }

        Divider()
        // Words, at the end of the list, with the other things you can do to this
        // episode. The picture already has a full-size copy at the top of the page, and a
        // second thumbnail of it in the middle of a list of fields read as a stray badge
        // rather than a control.
        HStack(spacing: 16) {
            PhotosPicker(selection: $artworkItem, matching: .images) {
                Label(track.artworkFileName == nil ? "Add Photo" : "Change Photo", systemImage: "photo")
                    .font(.footnote)
            }
            if track.artworkFileName != nil {
                Button("Remove Photo", role: .destructive) { setArtwork(nil) }
                    .font(.footnote)
            }
            Spacer(minLength: 0)
        }

        Button {
            Task { await suggest() }
        } label: {
            HStack(spacing: 6) {
                Label("Suggest with AI", systemImage: "sparkles")
                if isSuggesting { ProgressView().controlSize(.mini) }
            }
            .font(.footnote)
        }
        .disabled(isSuggesting || !readiness.isReady)
        if let blockedReason = readiness.blockedReason {
            Text(blockedReason).font(.caption).foregroundStyle(.secondary)
        }
        if let suggestionError {
            Text(suggestionError).font(.caption).foregroundStyle(.orange)
        }
    }

    private var folder: String? {
        let folder = (track.filePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    private var fileExtension: String? {
        let ext = (track.filePath as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private static func formatted(_ date: Date?) -> String? {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) }
    }

    private func load() async {
        latest = (try? trackStore.find(id: playingTrack.id)) ?? nil
        artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
        album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
        show = track.showID.flatMap { try? libraryStore.show(id: $0) } ?? nil
        topics = show.flatMap { try? libraryStore.topics(forShow: $0.id) } ?? []
        connectionLabel = (try? providerStore.all())?.first { $0.id == track.providerID }?.label
        downloadedBytes = await AudioCache.shared.cachedSize(providerID: track.providerID, filePath: track.filePath)
        bookmarks = (try? bookmarkStore.all(forTrack: track.id)) ?? []
        // Half-typed words outrank whatever the database says — a sync landing mid-edit
        // must not pull the text out from under the cursor. A different track is the one
        // exception: those words have nowhere left to go.
        guard draftTrackID != track.id || (focusedField == nil && snapshot == savedSnapshot) else { return }
        if draftTrackID != track.id { focusedField = nil }
        fillFields()
    }

    private func fillFields() {
        title = track.title
        artistName = artist?.name ?? ""
        albumName = album?.name ?? ""
        showName = show?.name ?? ""
        year = track.year.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        notes = track.notes ?? ""
        draftTrackID = track.id
        savedSnapshot = snapshot
    }

    private var snapshot: String {
        [title, artistName, albumName, showName, year, trackNumber, notes].joined(separator: "\u{1}")
    }

    private func save() {
        guard draftTrackID == track.id, snapshot != savedSnapshot else { return }
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
        updated.metadataEditedAt = Date()
        try? trackStore.saveEdit(updated, artistName: artist?.name, albumName: album?.name)
        savedSnapshot = snapshot
        // Home and the player hold their own copies of these rows, so they need telling —
        // otherwise the edit only lands after some unrelated refresh.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func handleArtworkPick(_ item: PhotosPickerItem?) async {
        guard let item, let picked = try? await item.loadTransferable(type: PickedImageFile.self) else { return }
        defer { picked.discard() }
        guard let fileName = try? await ImageFileStore.artwork.save(contentsOf: picked.url, maxDimension: 800) else { return }
        setArtwork(fileName)
    }

    /// Artwork saves on its own rather than waiting for a field to lose focus: picking a
    /// picture is already a deliberate, finished act.
    private func setArtwork(_ fileName: String?) {
        let previous = track.artworkFileName
        var updated = track
        updated.artworkFileName = fileName
        updated.metadataEditedAt = Date()
        try? trackStore.saveEdit(updated, artistName: artist?.name, albumName: album?.name)
        ImageFileStore.artwork.remove(previous)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
            save()
        } catch {
            suggestionError = error.localizedDescription
        }
        isSuggesting = false
    }

    private func trimmed(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionHeading()
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Where a field's value is also a page of its own — the chevron stays, so a speaker is
/// still one tap from their episodes even though the name is now editable in place.
private enum EpisodeField: Hashable {
    case title, speaker, album, show, year, trackNumber, notes
}

private enum EpisodeLink {
    case speaker(Artist)
    case album(Album)
    case show(Show)
}

/// How wide the label column is. Fixed, so every value in a card starts at the same
/// place and sits next to the word that names it. Pushing labels left and values right
/// put a hand's width of nothing between "Size" and "24.1 MB", and made a card of short
/// values read as two unrelated lists.
private enum DetailLayout {
    static let labelWidth: CGFloat = 104
}

/// Skips itself when there's no value, so an episode with thin metadata shows a short
/// card rather than a column of dashes. For anything editable see `EditableRow`.
private struct DetailRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .sectionRowSecondary()
                    .frame(width: DetailLayout.labelWidth, alignment: .leading)
                Text(value)
                    .font(.footnote)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// An editable field dressed as a detail row: the value sits in the same column the
/// read-only rows use, so a card doesn't visibly split into "things you can change" and
/// "things you can't". Shown even when empty — a blank Year is something to fill in, not
/// something to hide.
private struct EditableRow: View {
    let label: String
    @Binding var text: String
    let field: EpisodeField
    var focus: FocusState<EpisodeField?>.Binding
    var keyboard: UIKeyboardType = .default
    var link: EpisodeLink?
    var placeholder: String = "—"

    init(
        _ label: String, text: Binding<String>, field: EpisodeField,
        focus: FocusState<EpisodeField?>.Binding, keyboard: UIKeyboardType = .default,
        link: EpisodeLink? = nil, placeholder: String = "—"
    ) {
        self.label = label
        self._text = text
        self.field = field
        self.focus = focus
        self.keyboard = keyboard
        self.link = link
        self.placeholder = placeholder
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            // The placeholder is what the episode would show if this were left alone — the
            // album's year, say — rather than the field's own name, which the label to the
            // left already says.
            TextField(placeholder, text: $text)
                .font(.footnote)
                .keyboardType(keyboard)
                .focused(focus, equals: field)
                .submitLabel(.done)
                .onSubmit { focus.wrappedValue = nil }
            if let link {
                NavigationLink {
                    destination(link)
                } label: {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func destination(_ link: EpisodeLink) -> some View {
        switch link {
        case .speaker(let artist): SpeakerDetailView(speaker: artist)
        case .album(let album): AlbumDetailView(album: album)
        case .show(let show): ShowDetailView(show: show)
        }
    }
}

private struct TagRow: View {
    let names: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Topics")
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The episode's language, with the list of what this phone can actually recognise
/// offline. Its own view so the twice-a-second churn of a transcription run redraws one
/// row rather than every field on the page.
private struct EpisodeLanguageRow: View {
    @ObservedObject private var transcript = TranscriptRunner.shared
    @ObservedObject private var languages = OnDeviceLanguages.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Language")
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            TranscriptLanguageMenu(playing: transcript, languages: languages)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await languages.refreshIfNeeded() }
    }
}
