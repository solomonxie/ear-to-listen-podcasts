import Foundation
import GRDB

enum BackupError: Error, LocalizedError, Equatable {
    case noActiveRemoteProvider
    case noBackupFound
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .noActiveRemoteProvider: return "Add and activate a remote (S3) source first."
        case .noBackupFound: return "No backup found in that remote source."
        case .unsupportedVersion(let version): return "This backup (v\(version)) is newer than this app supports."
        }
    }
}

struct BackupImportResult {
    var playlistsImported: Int
    var tracksMatched: Int
    var tracksUnmatched: Int
}

/// Builds/applies `LibrarySnapshot`s against the local DB, and ships them to/from
/// whichever remote (S3) provider is active — see `Sources/Backup/README.md`.
struct BackupService {
    let dbQueue: DatabaseQueue
    private var playlistStore: PlaylistStore { PlaylistStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }
    private var importSourceStore: ImportSourceStore { ImportSourceStore(dbQueue: dbQueue) }
    private var trackStore: TrackStore { TrackStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var transcriptStore: TranscriptStore { TranscriptStore(dbQueue: dbQueue) }

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
        // Same rule for episodes: only the ones someone edited by hand travel, since a
        // re-sync re-derives everything else from the files themselves.
        let episodes = try trackStore.all(includingLost: true).compactMap { track -> LibrarySnapshot.EpisodeEntry? in
            guard let editedAt = track.metadataEditedAt else { return nil }
            return LibrarySnapshot.EpisodeEntry(
                providerID: track.providerID,
                filePath: track.filePath,
                title: track.title,
                artistName: (track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil)?.name,
                albumName: (track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil)?.name,
                showName: (track.showID.flatMap { try? libraryStore.show(id: $0) } ?? nil)?.name,
                year: track.year,
                trackNumber: track.trackNumber,
                notes: track.notes,
                artworkFileName: track.artworkFileName,
                editedAt: editedAt
            )
        }
        return LibrarySnapshot(
            exportedAt: Date(), playlists: playlists, providers: providers,
            importSources: importSources, artists: artists, episodes: episodes,
            transcripts: try transcripts()
        )
    }

    /// Unlike speaker/episode entries there's no "only if edited" rule here — a machine
    /// transcript is expensive to rebuild (battery or API spend) even when nobody has
    /// touched it, so all of it travels.
    private func transcripts() throws -> [LibrarySnapshot.TranscriptEntry] {
        let tracksByID = Dictionary(
            try trackStore.all(includingLost: true).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
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
    /// `photos/`, episode artwork under `artwork/`.
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
        return ZipArchive.write(entries)
    }

    /// Unpacks a zip written by `archive(_:)` — writes any bundled images to their store
    /// before returning, so `apply(_:)` can point restored speakers/episodes at them right
    /// away.
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

    /// Merges a snapshot into the local DB. Provider/import-source rows restore
    /// credential-less (settings stay in Keychain, keyed by id) — reconnect them via
    /// Settings after. Playlists restore by matching each track against whatever's
    /// currently synced locally via (providerID, filePath); tracks not yet synced are
    /// counted, not dropped from the count reported back, so the caller can tell the
    /// user to sync first.
    @discardableResult
    func apply(_ snapshot: LibrarySnapshot) throws -> BackupImportResult {
        let existingProviderIDs = Set(try providerStore.all().map(\.id))
        for entry in snapshot.providers where !existingProviderIDs.contains(entry.id) {
            try providerStore.upsert(ProviderRecord(
                id: entry.id, type: entry.type, label: entry.label, configJSON: "",
                isActive: entry.isActive, createdAt: entry.createdAt, syncFrequencyMinutes: entry.syncFrequencyMinutes
            ))
        }

        let existingImportSourceIDs = Set(try importSourceStore.all().map(\.id))
        for entry in snapshot.importSources where !existingImportSourceIDs.contains(entry.id) {
            try importSourceStore.upsert(ImportSourceRecord(id: entry.id, type: entry.type, label: entry.label, createdAt: entry.createdAt))
        }

        let existingPlaylistIDs = Set(try playlistStore.all().map(\.id))
        var matched = 0
        var unmatched = 0
        for entry in snapshot.playlists {
            if !existingPlaylistIDs.contains(entry.id) {
                try playlistStore.create(Playlist(id: entry.id, name: entry.name, source: entry.source, createdAt: entry.createdAt))
            }
            for ref in entry.tracks {
                guard let track = try trackStore.find(providerID: ref.providerID, filePath: ref.filePath) else {
                    unmatched += 1
                    continue
                }
                try playlistStore.addTrack(track.id, toPlaylist: entry.id, at: ref.position)
                matched += 1
            }
        }

        // Upserts by name (see `ArtistEntry`) so this both re-applies an edit onto a
        // speaker already synced locally, and pre-seeds one that hasn't synced yet — a
        // later sync's own `upsertArtist(name:)` will find and reuse this same row.
        for entry in snapshot.artists {
            let artist = try libraryStore.upsertArtist(name: entry.name)
            try libraryStore.updateArtist(id: artist.id, name: entry.name, bio: entry.bio, language: entry.language)
            try libraryStore.updateArtistPhoto(id: artist.id, photoFileName: entry.photoFileName)
        }

        // Episode edits need the file itself already synced — unlike a speaker, there's no
        // sensible row to pre-seed from a path alone. Restoring onto a fresh device, sync
        // first, then restore again.
        for entry in snapshot.episodes {
            guard var track = try trackStore.find(providerID: entry.providerID, filePath: entry.filePath) else { continue }
            let artist = try entry.artistName.map { try libraryStore.upsertArtist(name: $0) }
            let album = try entry.albumName.map { try libraryStore.upsertAlbum(name: $0, artistID: artist?.id) }
            let show = try entry.showName.map { try libraryStore.upsertShow(name: $0) }
            track.title = entry.title
            track.artistID = artist?.id
            track.albumID = album?.id
            track.showID = show?.id
            track.year = entry.year
            track.trackNumber = entry.trackNumber
            track.notes = entry.notes
            track.artworkFileName = entry.artworkFileName
            track.metadataEditedAt = entry.editedAt
            try trackStore.upsert(track, artistName: artist?.name, albumName: album?.name)
        }

        // Like episode edits, a transcript needs its file already synced — there's no row
        // to hang it off otherwise. Merging rather than overwriting means a correction
        // made on this device outlives a restore of an older backup.
        for entry in snapshot.transcripts {
            guard let track = try trackStore.find(providerID: entry.providerID, filePath: entry.filePath) else { continue }
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

        return BackupImportResult(playlistsImported: snapshot.playlists.count, tracksMatched: matched, tracksUnmatched: unmatched)
    }

    // MARK: Remote (S3) backup/restore

    func backupToRemote() async throws {
        try await activeS3Provider().uploadBackup(archive(makeSnapshot()))
    }

    @discardableResult
    func restoreFromRemote() async throws -> BackupImportResult {
        guard let data = try await activeS3Provider().downloadBackup() else {
            throw BackupError.noBackupFound
        }
        return try apply(unarchive(data))
    }

    private func activeS3Provider() throws -> S3Provider {
        guard let record = try providerStore.active().first(where: { $0.type == S3Provider.providerType }),
              let provider = try ProviderManager.shared.provider(for: record) as? S3Provider else {
            throw BackupError.noActiveRemoteProvider
        }
        return provider
    }
}
