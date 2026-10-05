import Foundation
import GRDB

enum BackupError: Error, LocalizedError, Equatable {
    case noActiveRemoteProvider
    case noBackupFound
    case emptyBackup
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .noActiveRemoteProvider: return "Add and activate a cloud source first."
        case .noBackupFound: return "No backup found in that remote source."
        case .emptyBackup: return "That backup is empty — your library was left alone."
        case .unsupportedVersion(let version): return "This backup (v\(version)) is newer than this app supports."
        }
    }
}

struct BackupImportResult {
    var playlistsImported: Int
    var tracksMatched: Int
    var tracksUnmatched: Int
    /// Hand edits and transcripts whose episode this device hasn't synced yet. Not lost —
    /// `PendingRestore` re-applies them once a sync has fetched the files they name.
    var editsAwaitingSync: Int = 0

    var awaitingSync: Int { tracksUnmatched + editsAwaitingSync }
}

/// How much of a snapshot to put back. A reinstall applies `everything` once, then
/// `PendingRestore` re-applies `needsSyncedTracks` after each sync until nothing is left
/// waiting — so a playlist or speaker deleted since the restore isn't quietly re-created.
enum BackupApplyScope {
    case everything
    case needsSyncedTracks
}

/// Builds/applies `LibrarySnapshot`s against the local DB, and ships them to/from
/// whichever cloud provider is active — see `Sources/Backup/README.md`.
struct BackupService {
    let dbQueue: DatabaseQueue
    private var playlistStore: PlaylistStore { PlaylistStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }
    private var termStore: TermStore { TermStore(dbQueue: dbQueue) }
    private var importSourceStore: ImportSourceStore { ImportSourceStore(dbQueue: dbQueue) }
    private var trackStore: TrackStore { TrackStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var transcriptStore: TranscriptStore { TranscriptStore(dbQueue: dbQueue) }
    private var bookmarkStore: BookmarkStore { BookmarkStore(dbQueue: dbQueue) }

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: Snapshot <-> DB

    func makeSnapshot() throws -> LibrarySnapshot {
        let playlists = try playlistStore.all().map { playlist in
            LibrarySnapshot.PlaylistEntry(
                id: playlist.id,
                name: playlist.name,
                source: playlist.source,
                createdAt: playlist.createdAt,
                tracks: try playlistStore.tracks(inPlaylist: playlist.id).enumerated().map { position, track in
                    LibrarySnapshot.TrackRef(providerID: track.providerID, filePath: track.filePath, title: track.title, position: position)
                }
            )
        }
        let providers = try providerStore.all().map {
            LibrarySnapshot.ProviderEntry(
                id: $0.id, type: $0.type, label: $0.label, isActive: $0.isActive,
                syncFrequencyMinutes: $0.syncFrequencyMinutes, createdAt: $0.createdAt
            )
        }
        let importSources = try importSourceStore.all().map {
            LibrarySnapshot.ImportSourceEntry(id: $0.id, type: $0.type, label: $0.label, createdAt: $0.createdAt)
        }
        // Only speakers with a manual edit travel — everything else is just synced
        // metadata `SyncEngine` rebuilds on its own.
        let artists = try libraryStore.artists().compactMap { artist -> LibrarySnapshot.ArtistEntry? in
            guard artist.bio != nil || artist.photoFileName != nil || artist.language != nil else { return nil }
            return LibrarySnapshot.ArtistEntry(
                name: artist.name, bio: artist.bio, language: artist.language,
                photoFileName: artist.photoFileName
            )
        }
        // Every synced episode travels, not just one someone marked: a bucket that's gone
        // by the time this comes back leaves nothing for a re-sync to rebuild it from, so
        // the archive has to be able to stand in for it — see `BackupService.apply`.
        //
        // One query per table, then matched in memory: asking per episode was two
        // queries times every episode in the library, seconds of work on a big one.
        let bookmarksByTrack = Dictionary(grouping: try bookmarkStore.all(), by: \.trackID)
            .mapValues { $0.sorted { $0.positionMs < $1.positionMs } }
        let termsByTrack = try termStore.mentionsByTrack()
        let artistNames = Dictionary(try libraryStore.allArtists().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let albumNames = Dictionary(try libraryStore.allAlbums().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let allTracks = try trackStore.everything()
        let episodes = allTracks.map { track -> LibrarySnapshot.EpisodeEntry in
            let bookmarks = bookmarksByTrack[track.id] ?? []
            let terms = termsByTrack[track.id] ?? [:]
            return LibrarySnapshot.EpisodeEntry(
                providerID: track.providerID,
                filePath: track.filePath,
                title: track.title,
                artistName: track.artistID.flatMap { artistNames[$0] },
                albumName: track.albumID.flatMap { albumNames[$0] },
                year: track.year,
                notes: track.notes,
                summary: track.summary,
                terms: terms,
                artworkFileName: track.artworkFileName,
                isFavorite: track.isFavorite,
                listenedAt: track.listenedAt,
                bookmarks: bookmarks.map {
                    LibrarySnapshot.EpisodeEntry.BookmarkEntry(
                        positionMs: $0.positionMs, note: $0.note, tags: $0.tags,
                        transcriptText: $0.transcriptText, createdAt: $0.createdAt
                    )
                },
                editedAt: track.metadataEditedAt,
                durationMs: track.durationMs,
                sizeBytes: track.sizeBytes,
                contentHash: track.contentHash,
                youTubeVideoID: track.youTubeVideoID,
                neglectedAt: track.neglectedAt
            )
        }
        return LibrarySnapshot(
            exportedAt: Date(), playlists: playlists, providers: providers,
            importSources: importSources, artists: artists, episodes: episodes,
            transcripts: try transcripts(of: allTracks)
        )
    }

    /// Unlike speaker/episode entries there's no "only if edited" rule here — a machine
    /// transcript is expensive to rebuild (battery or API spend) even when nobody has
    /// touched it, so all of it travels.
    private func transcripts(of tracks: [Track]) throws -> [LibrarySnapshot.TranscriptEntry] {
        let tracksByID = Dictionary(
            tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return try transcriptStore.allRecords().compactMap { record in
            guard let track = tracksByID[record.trackID] else { return nil }
            let segments = (try? transcriptStore.find(trackID: record.trackID)) ?? []
            guard !segments.isEmpty else { return nil }
            let edits = (try? transcriptStore.edits(trackID: record.trackID)) ?? []
            return LibrarySnapshot.TranscriptEntry(
                providerID: track.providerID,
                filePath: track.filePath,
                segments: segments,
                edits: edits.map {
                    LibrarySnapshot.TranscriptEntry.EditEntry(
                        id: $0.id, segmentStart: $0.segmentStart, originalText: $0.originalText,
                        editedText: $0.editedText, createdAt: $0.createdAt
                    )
                },
                engine: record.engine,
                updatedAt: record.updatedAt
            )
        }
    }

    func encode(_ snapshot: LibrarySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    func decode(_ data: Data) throws -> LibrarySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        guard snapshot.version <= LibrarySnapshot.currentVersion else {
            throw BackupError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    /// Bundles a snapshot with the images it references into one zip archive — the actual
    /// format shipped by Export/Backup. `snapshot.json` at the root, speaker photos under
    /// `photos/`, episode artwork under `artwork/`, and the change log under `change-log/`
    /// so the record of what was done outlives the phone it was done on.
    func archive(_ snapshot: LibrarySnapshot) throws -> Data {
        var entries = [ZipArchive.Entry(name: "snapshot.json", data: try encode(snapshot))]
        for artist in snapshot.artists {
            guard let fileName = artist.photoFileName,
                  let url = ImageFileStore.speakerPhotos.url(for: fileName),
                  let data = try? Data(contentsOf: url)
            else { continue }
            entries.append(ZipArchive.Entry(name: "photos/\(fileName)", data: data))
        }
        for episode in snapshot.episodes {
            guard let fileName = episode.artworkFileName,
                  let url = ImageFileStore.artwork.url(for: fileName),
                  let data = try? Data(contentsOf: url)
            else { continue }
            entries.append(ZipArchive.Entry(name: "artwork/\(fileName)", data: data))
        }
        // Carried, never applied: every line names row ids this device made up, and a
        // restore remaps them. It travels to be read, not replayed.
        for url in ChangeLog.files() {
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(ZipArchive.Entry(name: "change-log/\(url.lastPathComponent)", data: data))
        }
        return ZipArchive.write(entries)
    }

    /// Unpacks a zip written by `archive(_:)` — writes any bundled images to their store
    /// before returning, so `apply(_:)` can point restored speakers/episodes at them right
    /// away. Anything else in there, the change log included, is left where it is.
    func unarchive(_ data: Data) throws -> LibrarySnapshot {
        let entries = ZipArchive.read(data)
        guard let snapshotEntry = entries.first(where: { $0.name == "snapshot.json" }) else {
            throw BackupError.noBackupFound
        }
        for (prefix, store) in [("photos/", ImageFileStore.speakerPhotos), ("artwork/", ImageFileStore.artwork)] {
            for entry in entries where entry.name.hasPrefix(prefix) {
                let fileName = String(entry.name.dropFirst(prefix.count))
                try? entry.data.write(to: store.directory.appendingPathComponent(fileName))
            }
        }
        return try decode(snapshotEntry.data)
    }

    /// Merges a snapshot into the local DB, never overwriting what's already there.
    /// Playlist tracks, hand edits and transcripts are matched against what's synced
    /// locally by (providerID, filePath) — the only key that survives a reinstall.
    /// Whatever doesn't match yet is counted rather than dropped, so the caller can say
    /// "N items need a sync first" and `PendingRestore` can come back for them.
    @discardableResult
    func apply(_ snapshot: LibrarySnapshot, scope: BackupApplyScope = .everything) throws -> BackupImportResult {
        // Taken before the placeholders below are made: a bucket this device never had is
        // exactly as gone as one it deleted, and its placeholder must not read as "still
        // connected, just waiting to sync".
        let knownProviderIDs = Set(try providerStore.all().map(\.id))
        if scope == .everything {
            try applyDeviceIndependentEntries(snapshot)
        }

        var awaiting = 0

        // An episode whose source is still connected needs the file itself synced first —
        // unlike a speaker, there's no sensible row to pre-seed from a path alone, and a
        // sync that's merely pending (a fresh install, say) will still produce the real
        // row. What doesn't match yet in that case is counted, not dropped: `PendingRestore`
        // comes back for it after the next sync.
        //
        // One whose source is already gone never gets that sync, so there's nothing left
        // to wait for — it's fabricated straight from the archive instead, same as a
        // YouTube episode always is. Unless the path is ambiguous among what's already
        // here: that's the one case a guess is worse than waiting (see `track(named:)`),
        // and fabricating a stand-in would just be a second, wrong guess at the same risk.
        for entry in snapshot.episodes {
            var matched = try track(named: entry.providerID, at: entry.filePath) ?? youTubeEpisode(entry)
            if matched == nil, !knownProviderIDs.contains(entry.providerID),
               try trackStore.find(filePath: entry.filePath).count <= 1 {
                matched = orphanedEpisode(entry)
            }
            guard var track = matched else {
                awaiting += 1
                continue
            }
            var names = (speaker: entry.artistName, album: entry.albumName)
            if entry.providerID == YouTubeVideo.providerID || entry.youTubeVideoID != nil {
                let filed = YouTubeEpisodes.filing(speaker: names.speaker, album: names.album)
                names = (filed.speaker, filed.album)
            }
            let artist = try names.speaker.map { try libraryStore.upsertArtist(name: $0) }
            let album = try names.album.map { try libraryStore.upsertAlbum(name: $0, artistID: artist?.id) }
            track.title = entry.title
            track.artistID = artist?.id
            track.albumID = album?.id
            track.year = entry.year
            track.notes = entry.notes
            track.summary = entry.summary ?? track.summary
            track.artworkFileName = entry.artworkFileName
            track.isFavorite = track.isFavorite || entry.isFavorite
            track.listenedAt = track.listenedAt ?? entry.listenedAt
            track.metadataEditedAt = entry.editedAt
            track.youTubeVideoID = entry.youTubeVideoID ?? track.youTubeVideoID
            track.neglectedAt = track.neglectedAt ?? entry.neglectedAt
            try trackStore.upsert(track, artistName: artist?.name, albumName: album?.name)
            try restore(entry.bookmarks, on: track.id)
            if !entry.terms.isEmpty { try termStore.setTerms(entry.terms, forTrack: track.id) }
        }

        // After the episodes, so a playlist can hold one this restore just rebuilt.
        let existingPlaylistIDs = Set(try playlistStore.all().map(\.id))
        var matched = 0
        var unmatched = 0
        for entry in snapshot.playlists {
            if !existingPlaylistIDs.contains(entry.id) {
                // Re-applying after a sync never revives a playlist deleted since the
                // restore — it only finishes filling the ones still there.
                guard scope == .everything else { continue }
                try playlistStore.create(Playlist(id: entry.id, name: entry.name, source: entry.source, createdAt: entry.createdAt))
            }
            for ref in entry.tracks {
                guard let track = try track(named: ref.providerID, at: ref.filePath) else {
                    unmatched += 1
                    continue
                }
                try playlistStore.addTrack(track.id, toPlaylist: entry.id, at: ref.position)
                matched += 1
            }
        }
        // Like episode edits, a transcript needs its file already synced — there's no row
        // to hang it off otherwise. Merging rather than overwriting means a correction
        // made on this device outlives a restore of an older backup.
        for entry in snapshot.transcripts {
            guard let track = try track(named: entry.providerID, at: entry.filePath) else {
                awaiting += 1
                continue
            }
            let existing = (try? transcriptStore.find(trackID: track.id)) ?? []
            try transcriptStore.save(
                trackID: track.id,
                segments: TranscriptStore.merging(existing: existing, incoming: entry.segments),
                engine: entry.engine
            )
            try transcriptStore.restoreEdits(entry.edits.map {
                TranscriptEdit(
                    id: $0.id, trackID: track.id, segmentStart: $0.segmentStart,
                    originalText: $0.originalText, editedText: $0.editedText, createdAt: $0.createdAt
                )
            })
        }

        try libraryStore.hideFullyNeglectedParents()

        return BackupImportResult(
            playlistsImported: snapshot.playlists.count, tracksMatched: matched,
            tracksUnmatched: unmatched, editsAwaitingSync: awaiting
        )
    }

    /// A YouTube episode is nothing but its row, so restoring is making it again.
    private func youTubeEpisode(_ entry: LibrarySnapshot.EpisodeEntry) -> Track? {
        guard entry.providerID == YouTubeVideo.providerID, YouTubeVideo.isValidID(entry.filePath) else { return nil }
        return Track(
            id: UUID().uuidString, providerID: YouTubeVideo.providerID, filePath: entry.filePath,
            title: entry.title, durationMs: entry.durationMs, updatedAt: Date(), youTubeVideoID: entry.filePath
        )
    }

    /// An episode whose bucket is already gone by the time this archive comes back —
    /// there's no live row to attach to and no sync ever arrives to make one, so this
    /// fabricates it directly, same as a YouTube episode always is. Parked on the standing
    /// orphaned-episode source (`TrackStore.markOrphaned`'s own doing, if this device is
    /// the one that deleted the bucket) and carrying `sizeBytes`/`durationMs`, so a sync
    /// that finds the same recording somewhere else still re-links it by fingerprint.
    private func orphanedEpisode(_ entry: LibrarySnapshot.EpisodeEntry) -> Track {
        Track(
            id: UUID().uuidString,
            providerID: OrphanedEpisodes.providerID,
            filePath: OrphanedEpisodes.path(originalProviderID: entry.providerID, originalFilePath: entry.filePath),
            title: entry.title,
            durationMs: entry.durationMs,
            sizeBytes: entry.sizeBytes,
            contentHash: entry.contentHash,
            isLost: true,
            updatedAt: Date()
        )
    }

    /// The episode an entry names. (providerID, filePath) is the pair every backup keys
    /// by, but the id half only survives if the source row itself did: reconnecting a
    /// bucket after a reinstall used to mint a new one, and every edit, favourite,
    /// bookmark and transcript in the archive then waited for a match that could never
    /// happen. So a miss falls back to the path alone — which is what the listener would
    /// call the same episode — and only when it names exactly one here. Two sources
    /// holding the same path is the one case where guessing is worse than waiting.
    ///
    /// Checked before that fallback: an episode `orphanedEpisode` already fabricated once,
    /// found again by the deterministic path it was parked under — otherwise re-applying
    /// the same archive (`PendingRestore`, a second restore) would mint a duplicate every
    /// time rather than finding the one that's already here.
    private func track(named providerID: String, at filePath: String) throws -> Track? {
        if let exact = try trackStore.find(providerID: providerID, filePath: filePath) { return exact }
        if let orphaned = try trackStore.find(
            providerID: OrphanedEpisodes.providerID,
            filePath: OrphanedEpisodes.path(originalProviderID: providerID, originalFilePath: filePath)
        ) { return orphaned }
        let byPath = try trackStore.find(filePath: filePath)
        return byPath.count == 1 ? byPath.first : nil
    }

    /// Bookmarks are matched on the moment they mark, so restoring the same archive
    /// twice — or onto a device that has been marking the same episode — doesn't leave
    /// two marks a second apart.
    private func restore(_ entries: [LibrarySnapshot.EpisodeEntry.BookmarkEntry], on trackID: String) throws {
        let existing = try bookmarkStore.all(forTrack: trackID)
        for entry in entries where !existing.contains(where: { abs($0.positionMs - entry.positionMs) < 1_000 }) {
            var bookmark = try bookmarkStore.add(trackID: trackID, positionMs: entry.positionMs)
            bookmark.note = entry.note
            bookmark.tags = entry.tags
            bookmark.transcriptText = entry.transcriptText
            bookmark.createdAt = entry.createdAt
            try bookmarkStore.update(bookmark)
        }
    }

    /// The half of a snapshot that stands on its own — sources, playlists and speaker
    /// edits — none of which needs an episode file to have synced first. Provider and
    /// import-source rows come back credential-less (settings stay in the Keychain, keyed
    /// by id) and inactive regardless of what the snapshot says: `isActive` is what the
    /// sync scheduler and the cloud-backup destination loop over, and a row with no
    /// credentials in either would just fail on every pass until someone reconnects it
    /// in Settings — which is the same place that turns it back on.
    private func applyDeviceIndependentEntries(_ snapshot: LibrarySnapshot) throws {
        let existingProviderIDs = Set(try providerStore.all().map(\.id))
        for entry in snapshot.providers where !existingProviderIDs.contains(entry.id) {
            try providerStore.upsert(ProviderRecord(
                id: entry.id, type: entry.type, label: entry.label, configJSON: "",
                isActive: false, createdAt: entry.createdAt, syncFrequencyMinutes: entry.syncFrequencyMinutes
            ))
        }

        let existingImportSourceIDs = Set(try importSourceStore.all().map(\.id))
        for entry in snapshot.importSources where !existingImportSourceIDs.contains(entry.id) {
            try importSourceStore.upsert(ImportSourceRecord(id: entry.id, type: entry.type, label: entry.label, createdAt: entry.createdAt))
        }

        // Upserts by name (see `ArtistEntry`) so this both re-applies an edit onto a
        // speaker already synced locally, and pre-seeds one that hasn't synced yet — a
        // later sync's own `upsertArtist(name:)` will find and reuse this same row.
        for entry in snapshot.artists {
            let artist = try libraryStore.upsertArtist(name: entry.name)
            try libraryStore.updateArtist(id: artist.id, name: entry.name, bio: entry.bio, language: entry.language)
            try libraryStore.updateArtistPhoto(id: artist.id, photoFileName: entry.photoFileName)
        }
    }

    // MARK: Destinations

    /// The archive as it stands right now — built once per run and handed to every
    /// destination that's switched on, since walking the whole library twice for the same
    /// bytes is just twice the work.
    func currentArchive() throws -> Data {
        try archive(try makeSnapshot())
    }

    /// Whether an archive read back off a destination holds anything — what keeps a
    /// restore from taking the copy a wipe left behind while good ones sit beside it.
    /// Reads the JSON only: nothing is unpacked and nothing is written.
    func holdsData(_ archive: Data) -> Bool {
        snapshot(inArchive: archive).map { !$0.isEmpty } ?? false
    }

    /// The snapshot inside an archive and nothing else: the JSON is read, no image is
    /// unpacked and nothing is written. What "is this the copy I want?" is answered from,
    /// before anything is replaced.
    func snapshot(inArchive archive: Data) -> LibrarySnapshot? {
        guard let entry = ZipArchive.read(archive).first(where: { $0.name == "snapshot.json" }) else { return nil }
        return try? decode(entry.data)
    }

    func upload(_ archive: Data) async throws {
        try await activeRemoteProvider().uploadBackup(archive)
    }

    func uploadPreDeletion(_ archive: Data, named name: String) async throws {
        try await activeRemoteProvider().uploadBackup(archive, named: name)
    }

    /// The archive as the bucket holds it. Nothing applies it on its own — restoring is
    /// `FirstRunRestore`'s call, and it wants the bytes so it can keep them for
    /// `PendingRestore`.
    func downloadRemoteArchive() async throws -> Data? {
        try await activeRemoteProvider().downloadBackup(acceptable: holdsData)
    }

    /// The first connected bucket that takes writes, whichever cloud it's in — the
    /// archive is written through the `CloudProvider` protocol, so S3, COS, OSS, Azure and
    /// Google are all equally somewhere to put it.
    /// The bucket the app's own files go to, or nil when none is connected.
    func remoteProviderForAppData() -> CloudProvider? { try? activeRemoteProvider() }

    private func activeRemoteProvider() throws -> CloudProvider {
        for record in try providerStore.active() where record.cloudKind != nil {
            guard let provider = try? ProviderManager.shared.provider(for: record), provider.isWritable else { continue }
            return provider
        }
        throw BackupError.noActiveRemoteProvider
    }
}
