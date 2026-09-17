import AVFoundation
import Foundation
import GRDB

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
    /// The pass stopped early because the queue hit `SyncQueuePolicy.capacity`. What's
    /// left isn't missing, just not queued yet — the next sync carries on from there.
    var stoppedAtQueueLimit: Bool = false
}

enum SyncEngineError: Error, LocalizedError {
    case offline
    case queuePaused

    var errorDescription: String? {
        switch self {
        case .offline: return "You're offline. Connect to the internet to sync your library."
        case .queuePaused: return "The sync queue is paused. Resume it to sync."
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
        // Pause means pause: a scheduled or manual pass mustn't quietly keep importing
        // while the queue it reports into is stopped.
        guard !SyncQueuePolicy.isPaused else { throw SyncEngineError.queuePaused }
        guard NetworkMonitor.shared.isConnected else { throw SyncEngineError.offline }
        let provider = try ProviderManager.shared.provider(for: record)
        let files = try await provider.listFiles(inFolder: nil)
            .filter { FileKind(path: $0.path).isPlayable }

        // Taken from the listing rather than accumulated as the loop goes: what exists
        // remotely is what was listed, not how far the import got, and this pass can now
        // stop early (paused, or the queue filled up). Building it as it went would mark
        // everything past the stopping point as lost.
        let seenPaths = Set(files.map(\.path))
        var added = 0
        var stoppedAtQueueLimit = false
        for file in files {
            // Pausing mid-pass stops it where it stands rather than letting the rest of a
            // long listing run to completion.
            if SyncQueuePolicy.isPaused { break }
            let existing = try? trackStore.find(providerID: record.id, filePath: file.path)
            guard existing == nil || existing!.isLost || hasChanged(existing!, file) else { continue }
            // Already queued (adding a connection queues the whole listing) — let the
            // drain loop have it rather than importing the same file twice at once.
            if (try? jobStore.hasUnfinished(providerID: record.id, filePath: file.path)) == true { continue }

            let job: SyncJob
            do {
                job = try jobStore.enqueue(
                    providerID: record.id, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt
                )
            } catch {
                // The queue ceiling. Stop here instead of hammering it with every remaining
                // file — the rest come in on the next sync.
                stoppedAtQueueLimit = true
                break
            }
            try? jobStore.markRunning(id: job.id)
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
            do {
                if try await importFileIfNeeded(file, providerRecord: record, provider: provider, jobID: job.id) {
                    added += 1
                }
                try? jobStore.markDone(id: job.id)
            } catch {
                try? jobStore.markFailed(id: job.id, error: error.localizedDescription)
            }
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        }

        let lost = try trackStore.markLost(providerID: record.id, keepingPaths: seenPaths)
        try providerStore.updateLastSynced(id: record.id, at: Date())

        return SyncResult(
            added: added, lost: lost, totalFiles: files.count, stoppedAtQueueLimit: stoppedAtQueueLimit
        )
    }

    /// Imports one already-listed file if not yet known locally (or refreshes its
    /// size/hash/lost state if it's changed since); shared by the whole-bucket `sync`
    /// above and the per-file sync queue. Returns whether a new track was added.
    @discardableResult
    func importFileIfNeeded(
        _ file: CloudFile, providerRecord record: ProviderRecord, provider: CloudProvider, jobID: String? = nil
    ) async throws -> Bool {
        /// Reported per stage rather than per file, so the queue can say what's slow —
        /// reading tags off a remote file and waiting on an AI call take very different
        /// amounts of time and look identical otherwise.
        func stage(_ stage: SyncJobStage) {
            guard let jobID else { return }
            try? jobStore.markStage(id: jobID, stage)
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        }

        // The caller usually filters already, but this is the one door every episode comes
        // through — a backup or a cover image reaching it would become a silent, unplayable
        // "episode" that then syncs forever.
        guard FileKind(path: file.path).isPlayable else { return false }

        if let existing = try trackStore.find(providerID: record.id, filePath: file.path) {
            if existing.isLost || hasChanged(existing, file) {
                try trackStore.refresh(
                    id: existing.id, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt, isLost: false
                )
            }
            return false
        }

        stage(.readingTags)
        let metadata = await extractMetadata(provider: provider, fileID: file.path)
        stage(.askingAI)
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
        stage(.saving)
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
