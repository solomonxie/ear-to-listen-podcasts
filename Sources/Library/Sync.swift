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

    /// For the button that opens the picker. It names the question it answers, because
    /// it sits next to "Sync Now" as a second pill — on its own, "Manual" is a setting
    /// with no subject, and nobody reads a clock icon as "how often".
    var buttonLabel: String {
        switch self {
        case .manual: return "Freq: manual"
        case .minutes15: return "Freq: every 15 min"
        case .minutes30: return "Freq: every 30 min"
        case .hourly: return "Freq: every hour"
        case .hours6: return "Freq: every 6 hours"
        case .hours12: return "Freq: every 12 hours"
        case .daily: return "Freq: every day"
        }
    }
}

struct SyncResult {
    /// Files this pass put in the queue — not files imported. The importing happens after
    /// it returns, in `SyncQueueManager.drain()`, so `queued == 12` means twelve files
    /// *starting*, not twelve episodes in the library.
    var queued: Int
    var lost: Int
    var totalFiles: Int
    /// The pass stopped early because the queue hit `SyncQueuePolicy.capacity`. What's
    /// left isn't missing, just not queued yet — the drain tops it back up once there's room.
    var stoppedAtQueueLimit: Bool = false

    /// Both "Sync Now" buttons say the same thing, so they say it from here.
    var summary: String {
        var text: String
        if queued > 0 {
            text = "Queued \(queued) of \(totalFiles) files — importing in the background."
            if lost > 0 { text += " \(lost) missing." }
        } else if lost > 0 {
            text = "Nothing new. \(lost) no longer in the bucket."
        } else {
            text = "Up to date — \(totalFiles) files, nothing new."
        }
        if stoppedAtQueueLimit { text += " Stopped at the queue limit — syncing on as room frees up." }
        return text
    }
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

    /// Recursively lists the provider's files and queues every one that needs fetching —
    /// new, changed, or previously lost; unchanged files are skipped untouched. Then marks
    /// anything no longer in the listing as lost, and returns.
    ///
    /// It imports nothing itself: `SyncQueueManager.drain()` is the only thing that does,
    /// at whatever pace the queue is set to. This is why a bucket with thousands of files
    /// no longer holds a "Sync Now" button hostage for minutes, and why the queue's speed
    /// control applies to a whole-bucket pass the same as to anything else.
    func sync(providerRecord record: ProviderRecord) async throws -> SyncResult {
        // Pause means pause: a scheduled or manual pass mustn't quietly keep importing
        // while the queue it reports into is stopped.
        guard !SyncQueuePolicy.isPaused else { throw SyncEngineError.queuePaused }
        let provider = try ProviderManager.shared.provider(for: record)
        // A folder on this device is readable with the radios off.
        guard provider.isOnDevice || NetworkMonitor.shared.isConnected else { throw SyncEngineError.offline }
        // Listed whole, filtered after: the non-audio entries are what say which
        // episodes have a transcript sitting beside them.
        let listing = try await provider.listFiles(inFolder: nil)
        let sidecars = TranscriptFile.sidecarsByAudioPath(in: listing)
        let files = listing.filter { FileKind(path: $0.path).isPlayable }

        // Taken from the listing rather than accumulated as the loop goes: what exists
        // remotely is what was listed, not how far the import got, and this pass can now
        // stop early (paused, or the queue filled up). Building it as it went would mark
        // everything past the stopping point as lost.
        let seenPaths = Set(files.map(\.path))
        var queued = 0
        var stoppedAtQueueLimit = false
        for file in files {
            // Pausing mid-pass stops it where it stands rather than letting the rest of a
            // long listing run to completion.
            if SyncQueuePolicy.isPaused { break }
            let existing = try? trackStore.find(providerID: record.id, filePath: file.path)
            guard existing == nil || existing!.isLost || hasChanged(existing!, file) else { continue }
            // Already waiting or being worked — leave it where it is in the queue.
            if (try? jobStore.hasUnfinished(providerID: record.id, filePath: file.path)) == true { continue }

            do {
                _ = try jobStore.enqueue(
                    providerID: record.id, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt,
                    transcriptPath: sidecars[file.path]
                )
                queued += 1
            } catch {
                // The queue ceiling. Stop here instead of hammering it with every remaining
                // file — the drain tops up from this point once it's made room.
                stoppedAtQueueLimit = true
                break
            }
        }

        // A transcript added to the bucket later doesn't change the audio, so it never
        // queues anything — this is what notices it.
        try trackStore.updateTranscriptPaths(providerID: record.id, sidecars: sidecars)

        let lost = try trackStore.markLost(providerID: record.id, keepingPaths: seenPaths)
        try providerStore.updateLastSynced(id: record.id, at: Date())

        // Once, not per file: this is the hop out of here into the main-actor queue
        // manager, and it both refreshes the list and wakes the drain loop.
        NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)

        return SyncResult(
            queued: queued, lost: lost, totalFiles: files.count, stoppedAtQueueLimit: stoppedAtQueueLimit
        )
    }

    /// Works one already-claimed job: rebuilds the `CloudFile` the listing pass recorded,
    /// imports it, and closes the row either way. It lives here rather than on the
    /// main-actor queue manager because nothing about it needs the main actor — and
    /// because it's the only way a test can drive an import without one.
    func perform(_ job: SyncJob, providerRecord record: ProviderRecord) async {
        do {
            let provider = try ProviderManager.shared.provider(for: record)
            // An upload job has to put the file there before there's anything to import.
            // Same row, same retry: a failed upload is a failed job, not a lost episode.
            if job.uploadBookmark != nil {
                try? jobStore.markStage(id: job.id, .uploading)
                NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
                try await EpisodeUpload.send(job, provider: provider)
            }
            let file = CloudFile(
                id: job.filePath, name: job.displayName, path: job.filePath, sizeBytes: job.sizeBytes,
                mimeType: nil, modifiedAt: job.remoteModifiedAt, contentHash: job.contentHash
            )
            try await importFileIfNeeded(
                file, providerRecord: record, provider: provider, jobID: job.id,
                transcriptPath: job.transcriptPath
            )
            try? jobStore.markDone(id: job.id)
        } catch {
            try? jobStore.markFailed(id: job.id, error: error.localizedDescription)
        }
    }

    /// Imports one already-listed file if not yet known locally (or refreshes its
    /// size/hash/lost state if it's changed since); shared by the whole-bucket `sync`
    /// above and the per-file sync queue. Returns whether a new track was added.
    @discardableResult
    func importFileIfNeeded(
        _ file: CloudFile, providerRecord record: ProviderRecord, provider: CloudProvider,
        jobID: String? = nil, transcriptPath: String? = nil
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
            transcriptPath: transcriptPath,
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
