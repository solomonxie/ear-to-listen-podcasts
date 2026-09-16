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
            guard artist.bio != nil || artist.photoFileName != nil else { return nil }
            return LibrarySnapshot.ArtistEntry(name: artist.name, bio: artist.bio, photoFileName: artist.photoFileName)
        }
        return LibrarySnapshot(exportedAt: Date(), playlists: playlists, providers: providers, importSources: importSources, artists: artists)
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

    /// Bundles a snapshot with its referenced speaker photos into one zip archive — the
    /// actual format shipped by Export/Backup. `snapshot.json` at the root, photos under
    /// `photos/`.
    func archive(_ snapshot: LibrarySnapshot) throws -> Data {
        var entries = [ZipArchive.Entry(name: "snapshot.json", data: try encode(snapshot))]
        for artist in snapshot.artists {
            guard let fileName = artist.photoFileName,
                  let url = SpeakerPhotoStore.url(for: fileName),
                  let data = try? Data(contentsOf: url)
            else { continue }
            entries.append(ZipArchive.Entry(name: "photos/\(fileName)", data: data))
        }
        return ZipArchive.write(entries)
    }

    /// Unpacks a zip written by `archive(_:)` — writes any bundled photos to
    /// `SpeakerPhotoStore` before returning, so `apply(_:)` can point restored speakers at
    /// them right away.
    func unarchive(_ data: Data) throws -> LibrarySnapshot {
        let entries = ZipArchive.read(data)
        guard let snapshotEntry = entries.first(where: { $0.name == "snapshot.json" }) else {
            throw BackupError.noBackupFound
        }
        for entry in entries where entry.name.hasPrefix("photos/") {
            let fileName = String(entry.name.dropFirst("photos/".count))
            try? entry.data.write(to: SpeakerPhotoStore.directory.appendingPathComponent(fileName))
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
            try libraryStore.updateArtist(id: artist.id, name: entry.name, bio: entry.bio)
            try libraryStore.updateArtistPhoto(id: artist.id, photoFileName: entry.photoFileName)
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
