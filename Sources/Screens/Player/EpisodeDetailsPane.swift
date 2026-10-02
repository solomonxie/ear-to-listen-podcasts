import PhotosUI
import SwiftUI

/// What the episode is about, under the transport: one line of facts, the summary, the
/// terms it keeps coming back to, and the listener's own impressions — the things read
/// while listening. Title, speaker and album are already under the cover, and changing any
/// of it is Edit's sheet; the file, its size, its playlists and its picture fold away
/// under More details, unfolding in place.
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
    @State private var showingEdit = false
    @State private var showsMore = false
    @State private var isAddingTerm = false
    @State private var newTerm = ""
    /// Every place this episode's audio is — usually one, more when the same recording
    /// turned up in a second bucket or under a second name.
    @State private var copies: [FileLocation] = []

    @State private var title = ""
    @State private var artistName = ""
    @State private var albumName = ""
    @State private var year = ""
    @State private var reloadTask: Task<Void, Never>?
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
        VStack(alignment: .leading, spacing: 12) {
            if track.isLost {
                Label("Missing from the last sync — the file wasn't in the bucket listing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("ABOUT").sectionHeading()
                Spacer(minLength: 8)
                suggestButton
                Button("Edit") { showingEdit = true }
                    .font(.caption)
            }
            if let suggestionError {
                Text(suggestionError).font(.caption).foregroundStyle(.orange)
            } else if let blockedReason = readiness.blockedReason {
                Text(blockedReason).font(.caption2).foregroundStyle(.tertiary)
            }

            // The title, speaker and album are under the cover already; what's left fits
            // on one line, and changing any of it is what Edit is for.
            if let facts {
                Text(facts).font(.footnote).foregroundStyle(.secondary)
            }

            moreDetails

            EpisodeSummaryView(track: track, analyzeRequest: analyzeRequest, onAnalyzed: { loadTerms() })

            termsRow

            VStack(alignment: .leading, spacing: 6) {
                // Named for whose words these are: the only text on the page nobody but
                // the listener can write.
                Text("MY IMPRESSIONS").sectionHeading()
                TextField("What you made of it", text: $notes, axis: .vertical)
                    .font(.footnote)
                    .lineLimit(1...8)
                    .focused($focusedField, equals: .notes)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal)
        // The sheet posts nothing when it adds to a hand-made list, so the row reloads
        // on the way out rather than waiting for the next `libraryDidChange`.
        .sheet(isPresented: $showingAddToPlaylist, onDismiss: { loadPlaylists() }) {
            AddToPlaylistSheet(track: track)
        }
        .sheet(isPresented: $showingEdit) { EpisodeEditView(track: track) }
        .alert("Add a term", isPresented: $isAddingTerm) {
            TextField("Name", text: $newTerm)
            Button("Add") {
                let name = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { addTerm(name) }
                newTerm = ""
            }
            Button("Cancel", role: .cancel) { newTerm = "" }
        } message: {
            Text("Counted in the transcript.")
        }
        .task(id: playingTrack.id) { await load() }
        // Off the main actor: it reads every timed line of the transcript to work out how
        // much of the episode is covered, which is not something to do on the thread
        // drawing the page it sits on.
        .task(id: playingTrack.id) {
            let episode = track
            readiness = await Task.detached(priority: .utility) {
                EpisodeMetadataSuggester().readiness(track: episode)
            }.value
        }
        // Sync and the other editors hold their own copies of these rows; this is what
        // puts their changes on screen without waiting for the next track change.
        // Coalesced: a sync posts one of these per imported file, and each reload redraws
        // the card on the page being read.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            reloadTask?.cancel()
            reloadTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        // Leaving a field is the commit. Scrolling away, or the page closing, counts too.
        .onChange(of: focusedField) { previous, _ in
            if previous != nil { save() }
        }
        .onChange(of: artworkItem) { _, item in
            Task { await handleArtworkPick(item) }
        }
        .onDisappear { save() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    /// Year · length · size · language, whichever are known. Nil when none are.
    private var facts: String? {
        let language = (track.language ?? album?.language ?? artist?.language)
            .map { TranscriptPane.languageName(Locale(identifier: $0)) }
        let parts = [
            (track.year ?? album?.year).map(String.init),
            track.durationMs.map(TrackRow.formattedDuration),
            track.sizeBytes.map { $0.formatted(.byteCount(style: .file)) },
            language,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line, scrolled sideways: the names the episode keeps coming back to, most-said
    /// first. A wrapping wall of two dozen chips was most of the old card's height.
    private var termsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(terms) { term in
                    NavigationLink(value: PlayerRoute.term(term.term)) {
                        TermChip(term: term)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { removeTerm(term) }
                    }
                }
                Button { isAddingTerm = true } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a term")
            }
        }
    }

    /// What's looked up now and then — the file, the lists it's on, the
    /// picture — folded away, unfolding in place when asked for.
    @ViewBuilder
    private var moreDetails: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsMore.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("More details")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsMore ? 90 : 0))
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showsMore {
            VStack(alignment: .leading, spacing: 4) {
                // One row per copy: the same recording in two buckets is one episode with
                // two addresses, not two episodes.
                ForEach(Array(copies.enumerated()), id: \.element.id) { index, copy in
                    FilePathRow(label: index == 0 ? "File" : "Also at", location: copy)
                }
                PlaylistsRow(names: playlistNames, onAdd: { showingAddToPlaylist = true })
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
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
        }
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
    private nonisolated static func copies(of track: Track, providers records: [ProviderRecord]) -> [FileLocation] {
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


    /// Everything this card shows, read in one pass off the main actor and put on screen
    /// together. Eight queries and a keychain read for the file's bucket is not much, but
    /// it was all happening on the thread drawing the page as it slid in — the card has to
    /// fill in *after* the page opens, not before.
    private func load() async {
        let loaded = await Task.detached(priority: .userInitiated) { [playingTrack, libraryStore, trackStore, providerStore, playlistStore, termStore] in
            let track = ((try? trackStore.find(id: playingTrack.id)) ?? nil) ?? playingTrack
            return Loaded(
                track: track,
                artist: track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil,
                album: track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil,
                // Topics tag the collection an episode belongs to.
                topics: track.albumID.flatMap { try? libraryStore.topics(forAlbum: $0) } ?? [],
                // Listen Later first and named as itself: it's the app's own list, it isn't
                // in the playlists table, and "on the queue" is as much an answer to "what
                // lists is this on" as any hand-made one.
                playlistNames: (track.listenLater ? ["Listen Later"] : [])
                    + ((try? playlistStore.playlists(containingTrack: track.id)) ?? []).map(\.name),
                terms: (try? termStore.terms(forTrack: track.id)) ?? [],
                copies: Self.copies(of: track, providers: (try? providerStore.all()) ?? [])
            )
        }.value
        guard playingTrack.id == loaded.track.id else { return }
        latest = loaded.track
        artist = loaded.artist
        album = loaded.album
        topics = loaded.topics
        playlistNames = loaded.playlistNames
        terms = loaded.terms
        copies = loaded.copies
        // Half-typed words outrank whatever the database says — a sync landing mid-edit
        // must not pull the text out from under the cursor. A different track is the one
        // exception: those words have nowhere left to go.
        guard draftTrackID != track.id || (focusedField == nil && snapshot == savedSnapshot) else { return }
        if draftTrackID != track.id { focusedField = nil }
        fillFields()
    }

    /// Re-read on its own after the sheet adds this episode to a list — the whole card
    /// doesn't need rebuilding for one row.
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
        notes = track.notes ?? ""
        draftTrackID = track.id
        savedSnapshot = snapshot
    }

    private var snapshot: String {
        [title, artistName, albumName, year, notes].joined(separator: "\u{1}")
    }

    private func save() {
        guard draftTrackID == track.id, snapshot != savedSnapshot else { return }
        var names = (speaker: trimmed(artistName), album: trimmed(albumName))
        if track.youTubeID != nil {
            let filed = YouTubeEpisodes.filing(speaker: names.speaker, album: names.album)
            names = (filed.speaker, filed.album)
        }
        let artist = names.speaker.flatMap { try? libraryStore.upsertArtist(name: $0) }
        let album = names.album.flatMap { name in try? libraryStore.upsertAlbum(name: name, artistID: artist?.id) }

        var updated = track
        updated.title = trimmed(title) ?? TrackRow.fileName(for: track)
        updated.artistID = artist?.id
        updated.albumID = album?.id
        updated.year = trimmed(year).flatMap { Int($0) }
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
        if let fileName {
            let trackID = track.id
            Task.detached { await ArtworkSidecar.uploadEpisode(fileName, trackID: trackID) }
        }
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

/// The one field typed into on the card.
private enum EpisodeField: Hashable {
    case notes
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

/// Everything the card reads from the database, in one value — so one hop off the main
/// actor answers all of it and one assignment puts it on screen.
private struct Loaded: Sendable {
    var track: Track
    var artist: Artist?
    var album: Album?
    var topics: [Topic]
    var playlistNames: [String]
    var terms: [TermCount]
    var copies: [FileLocation]
}

/// One place the episode's audio is, ready to draw: the address as its own cloud writes
/// it, and what the bucket browser needs to open standing on it.
private struct FileLocation: Identifiable, Sendable {
    let id: String
    let providerID: String
    let filePath: String
    let label: String

    var folder: String? {
        let folder = (filePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

/// The file's whole address, which is the one value on this card that routinely doesn't
/// fit. A bucket, a couple of folders and an episode name is easily sixty characters, and
/// a path truncated to `s3://slmx-archives2/bible-au…` has lost the part that identifies
/// it — the end.
///
/// **Tapping it opens it up rather than going anywhere.** Reading the path is the common
/// want and the one the row can answer in place; it wraps to as many lines as it takes,
/// breaking mid-name, because a path is one long word and hyphenating it politely across
/// a column would be worse than either. The way into the bucket browser is then a labelled
/// row underneath, where it says what it does — rather than the whole row silently meaning
/// "leave this page", which is how it read when the value was clipped to one line and
/// there was nothing else a tap could have meant.
private struct FilePathRow: View {
    let label: String
    let location: FileLocation

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .sectionRowSecondary()
                    .frame(width: DetailLayout.labelWidth, alignment: .leading)
                Text(location.label)
                    .font(.subheadline)
                    .lineLimit(isOpen ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: DetailLayout.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
            }

            if isOpen {
                NavigationLink(
                    value: PlayerRoute.browse(
                        providerID: location.providerID, folder: location.folder,
                        highlight: location.filePath
                    )
                ) {
                    Label("Show in storage", systemImage: "folder")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.leading, DetailLayout.labelWidth + 8)
            }
        }
    }
}
