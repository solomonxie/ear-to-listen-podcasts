import AVFoundation
import Foundation
import GRDB

/// Not private: `SyncQueueManager.enqueueConnection` filters the same way when queuing
/// a whole connection's files.
let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"]

enum SyncFrequency: Int, CaseIterable, Identifiable {
    case manual = 0
    case minutes15 = 15
    case minutes30 = 30
    case hourly = 60
    case hours6 = 360
    case hours12 = 720
    case daily = 1440

    var id: Int { rawValue }

    init(minutes: Int?) {
        self = SyncFrequency(rawValue: minutes ?? 0) ?? .manual
    }

    var minutes: Int? { self == .manual ? nil : rawValue }

    var displayName: String {
        switch self {
        case .manual: return "Manual (no auto sync)"
        case .minutes15: return "Every 15 minutes"
        case .minutes30: return "Every 30 minutes"
        case .hourly: return "Every hour"
        case .hours6: return "Every 6 hours"
        case .hours12: return "Every 12 hours"
        case .daily: return "Every day"
        }
    }

    /// For showing the current setting on the row that opens the picker, where the full
    /// `displayName` would crowd out everything else.
    var shortName: String {
        switch self {
        case .manual: return "Manual"
        case .minutes15: return "15 min"
        case .minutes30: return "30 min"
        case .hourly: return "Hourly"
        case .hours6: return "6 hours"
        case .hours12: return "12 hours"
        case .daily: return "Daily"
        }
    }
}

struct SyncResult {
    var added: Int
    var lost: Int
    var totalFiles: Int
}

enum SyncEngineError: Error, LocalizedError {
    case offline

    var errorDescription: String? {
        switch self {
        case .offline: return "You're offline. Connect to the internet to sync your library."
        }
    }
}

struct SyncEngine {
    let dbQueue: DatabaseQueue
    private var trackStore: TrackStore { TrackStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }
    private var jobStore: SyncJobStore { SyncJobStore(dbQueue: dbQueue) }
    private let contentAnalyzer = ContentAnalyzer()

    /// `dbQueue` defaults to the shared app database; tests inject an in-memory one instead.
    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    /// Syncs every active provider's file listing into the local library.
    @discardableResult
    func syncActiveProviders() async throws -> Int {
        var total = 0
        for record in try providerStore.active() {
            total += try await sync(providerRecord: record).added
        }
        return total
    }

    /// Recursively lists the provider's files, adds any not yet in local metadata (reading
    /// embedded audio metadata, then optionally refining it via `ContentAnalyzer` if an
    /// OpenAI key is set), and marks any previously-known file no longer in the listing as lost.
    ///
    /// Runs sequentially rather than through `SyncQueueManager`'s drain loop — this is one
    /// whole-bucket pass, not something to parallelize — but every file that actually needs
    /// fetching (new, changed, or previously lost; unchanged files are skipped untouched)
    /// still gets a `SyncJob` row around it, so it shows up live in the sync queue exactly
    /// like a queued per-file import would.
    func sync(providerRecord record: ProviderRecord) async throws -> SyncResult {
        guard NetworkMonitor.shared.isConnected else { throw SyncEngineError.offline }
        let provider = try ProviderManager.shared.provider(for: record)
        let files = try await provider.listFiles(inFolder: nil)
            .filter { audioExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }

        var seenPaths: Set<String> = []
        var added = 0
        for file in files {
            seenPaths.insert(file.path)
            let existing = try? trackStore.find(providerID: record.id, filePath: file.path)
            guard existing == nil || existing!.isLost || hasChanged(existing!, file) else { continue }

            let job = try? jobStore.enqueue(
                providerID: record.id, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes,
                contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt
            )
            if let job { try? jobStore.markRunning(id: job.id) }
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
            do {
                if try await importFileIfNeeded(file, providerRecord: record, provider: provider) {
                    added += 1
                }
                if let job { try? jobStore.markDone(id: job.id) }
            } catch {
                if let job { try? jobStore.markFailed(id: job.id, error: error.localizedDescription) }
            }
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        }

        let lost = try trackStore.markLost(providerID: record.id, keepingPaths: seenPaths)
        try providerStore.updateLastSynced(id: record.id, at: Date())

        return SyncResult(added: added, lost: lost, totalFiles: files.count)
    }

    /// Imports one already-listed file if not yet known locally (or refreshes its
    /// size/hash/lost state if it's changed since); shared by the whole-bucket `sync`
    /// above and the per-file sync queue. Returns whether a new track was added.
    @discardableResult
    func importFileIfNeeded(_ file: CloudFile, providerRecord record: ProviderRecord, provider: CloudProvider) async throws -> Bool {
        if let existing = try trackStore.find(providerID: record.id, filePath: file.path) {
            if existing.isLost || hasChanged(existing, file) {
                try trackStore.refresh(
                    id: existing.id, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt, isLost: false
                )
            }
            return false
        }

        let metadata = await extractMetadata(provider: provider, fileID: file.path)
        let guess = await contentAnalyzer.analyze(
            filePath: file.path, title: metadata.title, artist: metadata.artist, album: metadata.album
        )
        let title = guess?.title ?? metadata.title ?? (file.name as NSString).deletingPathExtension
        let artistName = guess?.artist ?? metadata.artist
        let albumName = guess?.album ?? metadata.album
        let artist = try artistName.map { try libraryStore.upsertArtist(name: $0) }
        let album = try albumName.map { name in
            try libraryStore.upsertAlbum(name: name, artistID: artist?.id)
        }

        let track = Track(
            id: UUID().uuidString,
            providerID: record.id,
            artistID: artist?.id,
            albumID: album?.id,
            filePath: file.path,
            title: title,
            trackNumber: nil,
            durationMs: metadata.durationMs,
            year: metadata.year,
            sizeBytes: file.sizeBytes,
            contentHash: file.contentHash,
            remoteModifiedAt: file.modifiedAt,
            isLost: false,
            updatedAt: Date()
        )
        try trackStore.upsert(track, artistName: artistName, albumName: albumName)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return true
    }

    /// Whether the remote file looks like it's been overwritten in place since the last
    /// sync. Prefers the provider's content fingerprint (no download needed) since same-path,
    /// same-size overwrites are otherwise invisible; falls back to the remote modified date,
    /// then to size, for providers/files that don't supply a hash.
    private func hasChanged(_ existing: Track, _ file: CloudFile) -> Bool {
        if let newHash = file.contentHash {
            return newHash != existing.contentHash
        }
        if let newModifiedAt = file.modifiedAt, let oldModifiedAt = existing.remoteModifiedAt {
            return newModifiedAt != oldModifiedAt
        }
        return existing.sizeBytes != file.sizeBytes
    }

    private func extractMetadata(provider: CloudProvider, fileID: String) async -> (title: String?, artist: String?, album: String?, durationMs: Int?, year: Int?) {
        guard let url = try? await provider.streamURL(forFileID: fileID) else {
            return (nil, nil, nil, nil, nil)
        }
        let asset = AVURLAsset(url: url)
        guard let commonMetadata = try? await asset.load(.commonMetadata) else {
            return (nil, nil, nil, nil, nil)
        }

        var title: String?
        var artist: String?
        var album: String?
        var creationDate: String?
        for item in commonMetadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: album = try? await item.load(.stringValue)
            case .commonKeyCreationDate: creationDate = try? await item.load(.stringValue)
            default: break
            }
        }

        let durationSeconds = try? await asset.load(.duration).seconds
        let durationMs = durationSeconds.map { Int($0 * 1000) }
        let year = creationDate.flatMap { Int($0.prefix(4)) }
        return (title, artist, album, durationMs, year)
    }
}
