import PhotosUI
import SwiftUI

/// Everything known about what's playing — the tags that came off the file, and where the
/// file actually lives. Grouped cards rather than one flat list, so "who/what" doesn't
/// blur into "which file".
///
/// The dates are not here. Synced-at, changed-on-storage, details-edited: five rows
/// answering a question nobody was asking while listening, and all five are still in the
/// database for the things that do ask.
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
    @State private var topics: [Topic] = []
    @State private var playlistNames: [String] = []
    @State private var terms: [TermCount] = []
    @State private var showingAddToPlaylist = false
    /// Every place this episode's audio is — usually one, more when the same recording
    /// turned up in a second bucket or under a second name.
    @State private var copies: [FileLocation] = []

    @State private var title = ""
    /// Which unfolding control is open — one at a time, across the whole card.
    @State private var openPicker: String?
    @State private var artistName = ""
    @State private var albumName = ""
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

    @State private var artworkItem: PhotosPickerItem?
    @State private var isSuggesting = false
    /// Bumped to set the summary card going once the fields are in — see `suggestButton`.
    @State private var analyzeRequest = 0
    @State private var suggestionError: String?
    @State private var readiness: EpisodeMetadataSuggester.Readiness = .noTranscript

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let termStore = TermStore()

    private var track: Track { latest ?? playingTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if track.isLost {
                Label("Missing from the last sync — the file wasn't in the bucket listing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            DetailCard("Episode", accessory: { suggestButton }) { episodeFields }

            // Its own card, under the one whose ✨ produced it: the names an episode
            // talks about are a different kind of thing from its title and its year, and
            // there are two dozen of them.
            // Shown even when empty, now that terms can be added by hand: a card that
            // only appears once the AI has run can't be used to write the first one in.
            DetailCard("Terms") {
                TermsField(terms: terms, open: $openPicker, onAdd: { addTerm($0) }) { term in
                    NavigationLink(value: PlayerRoute.term(term.term)) {
                        TermChip(term: term)
                    }
                    .buttonStyle(.plain)
                    // Long press to remove, as everywhere else here — a second glyph
                    // inside the chip would be a target the size of a full stop, and
                    // tapping the chip has to keep meaning "go to it".
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            removeTerm(term)
                        }
                    }
                }
                // What the number on a chip counts changes with the page it's on —
                // this episode here, the whole collection on an album, the whole
                // library on Home — so each says which.
                Text("Times said in this episode — counted in the transcript, not guessed. Hold a term to remove it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            DetailCard("Notes") {
                TextField("What this episode is about", text: $notes, axis: .vertical)
                    .font(.footnote)
                    .lineLimit(2...8)
                    .focused($focusedField, equals: .notes)
            }

        }
        .padding(.horizontal)
        // The sheet posts nothing when it adds to a hand-made list, so the row reloads
        // on the way out rather than waiting for the next `libraryDidChange`.
        .sheet(isPresented: $showingAddToPlaylist, onDismiss: { loadPlaylists() }) {
            AddToPlaylistSheet(track: track)
        }
        .task(id: playingTrack.id) { await load() }
        .task(id: playingTrack.id) { readiness = EpisodeMetadataSuggester().readiness(track: track) }
        // Sync and the other editors hold their own copies of these rows; this is what
        // puts their changes on screen without waiting for the next track change.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await load() }
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
        // Why the heading's Suggest button is greyed out, and what came back when it
        // wasn't — at the top of the card, next to the control they belong to.
        if let blockedReason = readiness.blockedReason {
            Text(blockedReason).font(.caption).foregroundStyle(.secondary)
        }
        if let suggestionError {
            Text(suggestionError).font(.caption).foregroundStyle(.orange)
        }

        // One line, and deliberately not `axis: .vertical`: a vertical field treats
        // Return as "new paragraph", so Done added a blank row to the title instead of
        // putting the keyboard away.
        TextField("Title", text: $title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .focused($focusedField, equals: .title)
            .submitLabel(.done)
            .onSubmit { focusedField = nil }

        // Whole-row links rather than a text field with a chevron pinned to the far
        // edge. Going to the speaker's page is what anyone does from here; renaming the
        // speaker of one episode is what `EpisodeEditView` is for. One target per row,
        // and the target is the row.
        LinkRow("Speaker", value: artistName, route: artist.map { PlayerRoute.speaker($0.id) })
        LinkRow("Album", value: albumName, route: album.map { PlayerRoute.album($0.id) })

        // Up with who and what, not down among the numbers: language is inherited from
        // the speaker or the album above it, so it reads as the third answer to "what is
        // this", and it's what decides how the episode gets transcribed.
        EpisodeLanguageRow(open: $openPicker)

        UnfoldingWheel(
            title: "Year", id: "year", open: $openPicker, value: yearValue,
            choices: NumberChoices.years,
            placeholder: album?.year.map { "\($0) · from album" } ?? "—"
        )
        UnfoldingWheel(
            title: "Track no.", id: "trackNumber", open: $openPicker, value: trackNumberValue,
            choices: NumberChoices.trackNumbers
        )

        DetailRow("Duration", track.durationMs.map(TrackRow.formattedDuration))
        DetailRow("Size", track.sizeBytes.map { $0.formatted(.byteCount(style: .file)) })
        // Where the file actually is, written the way that cloud's own tooling writes it,
        // and a tap from the bucket browser standing on it. One row per copy: the same
        // recording in two buckets is one episode with two addresses, not two episodes.
        ForEach(Array(copies.enumerated()), id: \.element.id) { index, copy in
            LinkRow(
                index == 0 ? "File" : "Also at",
                value: copy.label,
                route: .browse(
                    providerID: copy.providerID, folder: copy.folder, highlight: copy.filePath
                )
            )
        }
        // Above Topics, which belong to the album: this is the one membership that's
        // about *this episode* and the one you decide while listening to it.
        PlaylistsRow(names: playlistNames, onAdd: { showingAddToPlaylist = true })
        // Shown even when empty now that it can be added to — an editable row that only
        // appears once it has something in it can't be used to put the first thing in.
        TagField(
            names: topics.map(\.name),
            ownerName: album?.name,
            labelWidth: DetailLayout.labelWidth,
            open: $openPicker,
            onChange: { names in
                guard let albumID = track.albumID else { return }
                try? libraryStore.setTopics(names, forAlbum: albumID)
                topics = (try? libraryStore.topics(forAlbum: albumID)) ?? []
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
        )

        Divider()
        // Words, at the end of the list, with the other things you can do to this
        // episode. The picture already has a full-size copy at the top of the page, and a
        // second thumbnail of it in the middle of a list of fields read as a stray badge
        // rather than a control.
        ArtworkSourceRow(
            subject: artworkSubject,
            hasArtwork: track.artworkFileName != nil,
            libraryPicker: {
                PhotosPicker(selection: $artworkItem, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
            },
            onUse: { data in Task { await saveArtwork(data) } },
            onRemove: { setArtwork(nil) }
        )

        Divider()
        // Last in the card and the only part of it written in sentences — the fields
        // above are what the episode *is*, this is what it says.
        EpisodeSummaryView(track: track, analyzeRequest: analyzeRequest, onAnalyzed: { loadTerms() })
    }

    /// **The page's one ✨.** It used to be two — this one for the fields, another in the
    /// summary's own heading — which asked the reader to know which half of "read this
    /// episode and tell me about it" each sparkle did. They are one pass now: the details,
    /// then the summary and the terms under it.
    ///
    /// Up in the card's heading rather than at the foot of the fields it fills in. Down
    /// there it sat a few points under the row of artwork buttons, which made one more
    /// capsule in a row of capsules — and it isn't an artwork control at all.
    private var suggestButton: some View {
        Button {
            Task { await suggest() }
        } label: {
            HStack(spacing: 5) {
                Label("Read with AI", systemImage: "sparkles")
                if isSuggesting { ProgressView().controlSize(.mini) }
            }
            .font(.caption)
        }
        .disabled(isSuggesting || !readiness.isReady)
    }

    /// One listing of the sources, not one per copy: an episode with three addresses
    /// otherwise asked the same question three times.
    private func loadCopies() -> [FileLocation] {
        let records = (try? providerStore.all()) ?? []
        let files = (try? TrackFileStore(dbQueue: DatabaseManager.shared.dbQueue).all(forTrack: track.id)) ?? []
        // The copy it plays from reads first, whatever order they were found in.
        let ordered = files.sorted { left, _ in
            left.providerID == track.providerID && left.filePath == track.filePath
        }
        return ordered.compactMap { file in
            guard let record = records.first(where: { $0.id == file.providerID }) else { return nil }
            let uri = ProviderManager.shared.fileURI(for: record, filePath: file.filePath)
                ?? "\(record.label)/\(file.filePath)"
            return FileLocation(
                id: file.id, providerID: file.providerID, filePath: file.filePath,
                // Said on the row rather than left to be discovered by tapping it: a link
                // to a file that isn't there any more is worse than a plain line of text.
                label: file.isLost ? "\(uri) — missing" : uri
            )
        }
    }

    /// The wheels speak `Int?`; the fields behind them are still the strings the save
    /// path parses, so nothing downstream has to change.
    private var yearValue: Binding<Int?> {
        Binding(get: { Int(year) }, set: { year = $0.map(String.init) ?? "" })
    }

    private var trackNumberValue: Binding<Int?> {
        Binding(get: { Int(trackNumber) }, set: { trackNumber = $0.map(String.init) ?? "" })
    }

    private func load() async {
        latest = (try? trackStore.find(id: playingTrack.id)) ?? nil
        artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
        album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
        // Topics tag the collection an episode belongs to.
        topics = track.albumID.flatMap { try? libraryStore.topics(forAlbum: $0) } ?? []
        loadPlaylists()
        loadTerms()
        copies = loadCopies()
        // Half-typed words outrank whatever the database says — a sync landing mid-edit
        // must not pull the text out from under the cursor. A different track is the one
        // exception: those words have nowhere left to go.
        guard draftTrackID != track.id || (focusedField == nil && snapshot == savedSnapshot) else { return }
        if draftTrackID != track.id { focusedField = nil }
        fillFields()
    }

    /// Listen Later first and named as itself: it's the app's own list, it isn't in the
    /// playlists table, and "on the queue" is as much an answer to "what lists is this on"
    /// as any hand-made one.
    private func loadPlaylists() {
        let made = ((try? playlistStore.playlists(containingTrack: track.id)) ?? []).map(\.name)
        playlistNames = (track.listenLater ? ["Listen Later"] : []) + made
    }

    private func loadTerms() {
        terms = (try? termStore.terms(forTrack: track.id)) ?? []
    }

    /// The count comes from the transcript, not from whoever typed the term: one said
    /// forty times and one the recording never says are different things, and only the
    /// transcript knows which this is.
    private func addTerm(_ name: String) {
        let spoken = ((try? TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)
            .find(trackID: track.id)) ?? [])?
            .map(\.text).joined(separator: " ") ?? ""
        try? termStore.add(
            name: name, mentions: EpisodeSummarizer.occurrences(of: name, in: spoken),
            forTrack: track.id
        )
        loadTerms()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func removeTerm(_ term: TermCount) {
        try? termStore.remove(termID: term.term.id, fromTrack: track.id)
        loadTerms()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func fillFields() {
        title = track.title
        artistName = artist?.name ?? ""
        albumName = album?.name ?? ""
        year = track.year.map(String.init) ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        notes = track.notes ?? ""
        draftTrackID = track.id
        savedSnapshot = snapshot
    }

    private var snapshot: String {
        [title, artistName, albumName, year, trackNumber, notes].joined(separator: "\u{1}")
    }

    private func save() {
        guard draftTrackID == track.id, snapshot != savedSnapshot else { return }
        let artist = trimmed(artistName).flatMap { try? libraryStore.upsertArtist(name: $0) }
        let album = trimmed(albumName).flatMap { name in try? libraryStore.upsertAlbum(name: name, artistID: artist?.id) }

        var updated = track
        updated.title = trimmed(title) ?? TrackRow.fileName(for: track)
        updated.artistID = artist?.id
        updated.albumID = album?.id
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

    /// What the model is told this episode is. Everything already known about it, in the
    /// order that identifies it fastest — nobody should have to type their own library
    /// back into a prompt box.
    private var artworkSubject: ArtworkSubject {
        ArtworkSubject(
            kind: .episode,
            name: track.title,
            details: [
                artistName.nilIfEmpty.map { "speaker \($0)" },
                albumName.nilIfEmpty.map { "from \($0)" },
                year.nilIfEmpty,
                topics.isEmpty ? nil : topics.map(\.name).joined(separator: ", "),
                notes.nilIfEmpty,
            ].compactMap { $0 }
        )
    }

    private func saveArtwork(_ data: Data) async {
        guard let fileName = try? await ImageFileStore.artwork.save(data, maxDimension: 800) else { return }
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
                track: track, title: title, artist: artistName, album: albumName, notes: notes
            )
            // Only fills what the model actually improved on — a null field leaves
            // whatever's in the form alone rather than blanking it.
            if let suggested = suggestion.title { title = suggested }
            if let suggested = suggestion.artist { artistName = suggested }
            if let suggested = suggestion.album { albumName = suggested }
            if let suggested = suggestion.year { year = String(suggested) }
            if let suggested = suggestion.notes { notes = suggested }
            save()
        } catch {
            suggestionError = error.localizedDescription
        }
        isSuggesting = false
        // The summary card runs the second half — it owns that text and what's on screen
        // of it, so asking it to go is a truer move than writing the row from out here.
        // It declines by itself if there's already a summary or no transcript to read.
        analyzeRequest += 1
    }

    private func trimmed(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct DetailCard<Content: View, Accessory: View>: View {
    let title: String
    /// The one action that belongs to the whole card, sitting on its heading line.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(
        _ title: String, @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).sectionHeading()
                Spacer(minLength: 8)
                accessory
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension DetailCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Where a field's value is also a page of its own — the chevron stays, so a speaker is
/// still one tap from their episodes even though the name is now editable in place.
private enum EpisodeField: Hashable {
    case title, speaker, album, year, trackNumber, notes
}

/// How wide the label column is. Fixed, so every value in a card starts at the same
/// place and sits next to the word that names it. Pushing labels left and values right
/// put a hand's width of nothing between "Size" and "24.1 MB", and made a card of short
/// values read as two unrelated lists.
private enum DetailLayout {
    static let labelWidth: CGFloat = 104
    /// Apple's minimum touch target. These rows are a column of fields on a page you're
    /// using one-handed while something plays — `.footnote` text with no padding gave a
    /// ~22pt row, which is a target you aim at rather than hit.
    static let rowHeight: CGFloat = 44
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
            HStack(spacing: 8) {
                Text(label)
                    .sectionRowSecondary()
                    .frame(width: DetailLayout.labelWidth, alignment: .leading)
                Text(value)
                    .font(.subheadline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: DetailLayout.rowHeight)
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
    var placeholder: String = "—"

    init(
        _ label: String, text: Binding<String>, field: EpisodeField,
        focus: FocusState<EpisodeField?>.Binding, keyboard: UIKeyboardType = .default,
        placeholder: String = "—"
    ) {
        self.label = label
        self._text = text
        self.field = field
        self.focus = focus
        self.keyboard = keyboard
        self.placeholder = placeholder
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            // The placeholder is what the episode would show if this were left alone — the
            // album's year, say — rather than the field's own name, which the label to the
            // left already says.
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .keyboardType(keyboard)
                .focused(focus, equals: field)
                .submitLabel(.done)
                .onSubmit { focus.wrappedValue = nil }
        }
        .frame(minHeight: DetailLayout.rowHeight)
        .contentShape(Rectangle())
    }
}

/// Which lists this episode is on, and the way onto another one. Chips rather than a
/// line of text: an episode is on none or a few, and "none" has to still be a control —
/// a row that only appears once it has something in it can't be used to put the first
/// thing in. Taking it off a list stays on the list's own page, where the rest of that
/// list is visible to take it out of.
private struct PlaylistsRow: View {
    let names: [String]
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Playlists")
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DetailLayout.rowHeight)
    }
}

/// A row whose whole width goes somewhere — the speaker's page, the album's.
///
/// The value is in the accent colour and the chevron sits where iOS puts it, but neither
/// is the target: the row is. A chevron alone, at the far edge, is both invisible as an
/// affordance and a long reach from the text you were reading when you decided to tap.
private struct LinkRow: View {
    let label: String
    let value: String
    /// A route, not a view: the player's stack routes these so the now-playing bar can
    /// follow onto the pushed page and pop back from it.
    let route: PlayerRoute?

    init(_ label: String, value: String, route: PlayerRoute?) {
        self.label = label
        self.value = value
        self.route = route
    }

    var body: some View {
        if let route {
            NavigationLink(value: route) {
                row(isLink: true)
            }
            .buttonStyle(.plain)
        } else if !value.isEmpty {
            row(isLink: false)
        }
    }

    private func row(isLink: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .sectionRowSecondary()
                .frame(width: DetailLayout.labelWidth, alignment: .leading)
            // No chevron. The accent colour already says "this goes somewhere", and the
            // whole row is the target — an arrow at the far edge added a second thing to
            // look at that pointed back at what you'd already decided to tap.
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline)
                .foregroundStyle(isLink ? Color.accentColor : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: DetailLayout.rowHeight)
        .contentShape(Rectangle())
    }

}

/// One place the episode's audio is, ready to draw: the address as its own cloud writes
/// it, and what the bucket browser needs to open standing on it.
private struct FileLocation: Identifiable {
    let id: String
    let providerID: String
    let filePath: String
    let label: String

    var folder: String? {
        let folder = (filePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

/// The episode's language. Its own view so the twice-a-second churn of a transcription
/// run redraws one row rather than every field on the page.
private struct EpisodeLanguageRow: View {
    @Binding var open: String?
    @ObservedObject private var transcript = TranscriptRunner.shared

    var body: some View {
        // No label column here — the field draws its own row, like the wheels beside it.
        EpisodeLanguageField(playing: transcript, id: "language", open: $open)
            .equatable()
    }
}
