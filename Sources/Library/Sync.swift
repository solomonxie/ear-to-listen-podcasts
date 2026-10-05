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
            text = "Added \(queued) of \(totalFiles) files — reading their tags in the background."
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
    private var trackFileStore: TrackFileStore { TrackFileStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }
    private var jobStore: SyncJobStore { SyncJobStore(dbQueue: dbQueue) }
    private let contentAnalyzer: ContentAnalyzer?

    /// `dbQueue` defaults to the shared app database; tests inject an in-memory one instead,
    /// and no analyzer — on a phone it would reach the listener's real AI keys.
    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue, contentAnalyzer: ContentAnalyzer? = ContentAnalyzer()) {
        self.dbQueue = dbQueue
        self.contentAnalyzer = contentAnalyzer
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
        let listingJob = try? jobStore.startListing(providerID: record.id, label: record.label)
        NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        var summary: String?
        defer {
            if let id = listingJob?.id {
                if let summary {
                    try? jobStore.finishListing(id: id, summary: summary)
                } else {
                    try? jobStore.markFailed(id: id, error: "The listing didn't finish.")
                }
                NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
            }
        }
        // Listed whole, filtered after: the non-audio entries are what say which
        // episodes have a transcript sitting beside them.
        let listing = try await provider.listFiles(inFolder: nil)
        let sidecars = TranscriptFile.sidecarSetsByAudioPath(in: listing)
        let artwork = ArtworkSidecar.find(in: listing)
        ArtworkSidecar.remember(artwork, providerID: record.id)
        let files = listing.filter { FileKind(path: $0.path).isPlayable }

        // Taken from the listing rather than accumulated as the loop goes: what exists
        // remotely is what was listed, not how far the import got, and this pass can now
        // stop early (paused, or the queue filled up). Building it as it went would mark
        // everything past the stopping point as lost.
        // Neglected episodes are left exactly as they are: not re-checked, not re-queued,
        // and not marked lost for being absent.
        let neglected = (try? trackStore.neglectedPaths(providerID: record.id)) ?? []
        let seenPaths = Set(files.map(\.path)).union(neglected)
        var queued = 0
        var stoppedAtQueueLimit = false

        // Scan: every file the library hasn't seen becomes an entry right now, from the
        // listing alone, in one write. Tags are read afterwards (`enrich`), so the whole
        // bucket is visible after one listing no matter how big it is — and the work
        // that's left is recorded on the entries, so it survives the app quitting.
        // Known copies are read once, not asked per file.
        let knownCopies = (try? trackFileStore.byPath(providerID: record.id)) ?? [:]
        var fresh: [CloudFile] = []
        for file in files {
            if SyncQueuePolicy.isPaused { break }
            if neglected.contains(file.path) { continue }
            guard let known = knownCopies[file.path] else {
                // Named for a YouTube episode: attaching to it is the import path's job.
                if YouTubeVideo.id(inFileName: file.path) == nil {
                    fresh.append(file)
                    continue
                }
                if let job = try? enqueueImport(file, record: record, sidecars: sidecars) { queued += job }
                continue
            }
            guard known.isLost || hasChanged(known, file) else { continue }
            if (try? jobStore.hasUnfinished(providerID: record.id, filePath: file.path)) == true { continue }
            do {
                queued += try enqueueImport(file, record: record, sidecars: sidecars)
            } catch {
                stoppedAtQueueLimit = true
                break
            }
        }
        if !fresh.isEmpty, !SyncQueuePolicy.isPaused {
            queued += (try? trackStore.registerListed(fresh, providerID: record.id, sidecars: sidecars)) ?? 0
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }

        // A transcript added to the bucket later doesn't change the audio, so it never
        // queues anything — this is what notices it.
        try trackStore.updateTranscriptPaths(providerID: record.id, sidecars: sidecars)
        // Likewise a picture; the episodes still in the queue take theirs in `perform`.
        await ArtworkSidecar.adopt(artwork, providerID: record.id, provider: provider, dbQueue: dbQueue)
        // And transcripts for YouTube episodes, which have no audio to sit beside.
        await YouTubeTranscripts.adopt(listing, provider: provider, dbQueue: dbQueue)

        let lost = try trackStore.markLost(providerID: record.id, keepingPaths: seenPaths)
        if !stoppedAtQueueLimit { try providerStore.updateLastSynced(id: record.id, at: Date()) }

        // Once, not per file: this is the hop out of here into the main-actor queue
        // manager, and it both refreshes the list and wakes the drain loop.
        NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)

        summary = "Listed \(record.label): \(files.count) files · \(queued) new"
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
            if job.kind == .readTags {
                try? jobStore.markStage(id: job.id, .readingTags)
                NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
                guard let trackID = job.trackID, let track = try trackStore.find(id: trackID), track.needsTags else {
                    try? jobStore.markDone(id: job.id)
                    return
                }
                if let failure = await enrich(track, provider: provider) {
                    try? jobStore.markFailed(id: job.id, error: failure)
                } else {
                    try? jobStore.markDone(id: job.id)
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
                return
            }
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
            let added = try await importFileIfNeeded(
                file, providerRecord: record, provider: provider, jobID: job.id,
                transcriptPath: job.transcriptPath, transcriptPaths: job.transcriptPaths
            )
            if added, let artwork = ArtworkSidecar.remembered(providerID: record.id) {
                await ArtworkSidecar.adopt(artwork, providerID: record.id, provider: provider, onlyPath: file.path, dbQueue: dbQueue)
            }
            try? jobStore.markDone(id: job.id)
        } catch {
            try? jobStore.markFailed(id: job.id, error: error.localizedDescription)
        }
    }

    /// Imports one already-listed file if not yet known locally (or refreshes its
    /// size/hash/lost state if it's changed since); shared by the whole-bucket `sync`
    /// above and the per-file sync queue. Returns whether a new track was added — a file
    /// that turns out to be a copy of an episode already here adds none, it adds a place
    /// that episode lives (`TrackStore.upsert`).
    @discardableResult
    func importFileIfNeeded(
        _ file: CloudFile, providerRecord record: ProviderRecord, provider: CloudProvider,
        jobID: String? = nil, transcriptPath: String? = nil, transcriptPaths: [String]? = nil
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

        if let known = try trackFileStore.find(providerID: record.id, filePath: file.path) {
            if known.isLost || hasChanged(known, file) {
                try trackStore.refreshCopy(
                    known, sizeBytes: file.sizeBytes, contentHash: file.contentHash,
                    remoteModifiedAt: file.modifiedAt
                )
            }
            return false
        }

        // Named with a YouTube episode's video ID: that episode's audio, not a new one.
        if let videoID = YouTubeVideo.id(inFileName: file.path),
           let episode = try trackStore.find(youTubeVideoID: videoID) {
            stage(.saving)
            try trackStore.attach(
                TrackFile(
                    trackID: episode.id, providerID: record.id, filePath: file.path, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, transcriptPath: transcriptPath, transcriptPaths: transcriptPaths,
                    remoteModifiedAt: file.modifiedAt
                ),
                toYouTubeEpisode: episode.id
            )
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            return false
        }

        // Same ETag and byte count as an episode that lost its audio: it's that episode,
        // known from the listing alone — no tags read, nothing downloaded.
        let fresh = TrackFile(
            trackID: "", providerID: record.id, filePath: file.path, sizeBytes: file.sizeBytes,
            contentHash: file.contentHash, transcriptPath: transcriptPath, transcriptPaths: transcriptPaths,
            remoteModifiedAt: file.modifiedAt
        )
        if try trackStore.relinkLostEpisode(to: fresh) {
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            return false
        }

        stage(.readingTags)
        let metadata = await extractMetadata(provider: provider, fileID: file.path)
        stage(.askingAI)
        let guess = await contentAnalyzer?.analyze(
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
            durationMs: metadata.durationMs,
            year: metadata.year,
            sizeBytes: file.sizeBytes,
            contentHash: file.contentHash,
            transcriptPath: transcriptPath,
            transcriptPaths: transcriptPaths,
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
    private func enqueueImport(_ file: CloudFile, record: ProviderRecord, sidecars: [String: [String]]) throws -> Int {
        _ = try jobStore.enqueue(
            providerID: record.id, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes,
            contentHash: file.contentHash, remoteModifiedAt: file.modifiedAt,
            transcriptPath: sidecars[file.path]?.first, transcriptPaths: sidecars[file.path]
        )
        return 1
    }

    /// The tag half of a sync: reads what the file says about itself and fills in the entry
    /// the scan made. Returns why it couldn't, or nil on success — an entry that can't be
    /// read keeps waiting for a later pass rather than being marked done.
    func enrich(_ track: Track, provider: CloudProvider) async -> String? {
        guard let url = try? await provider.streamURL(forFileID: track.filePath) else {
            return "couldn't get a link to the file"
        }
        let metadata = await extractMetadata(url: url)
        guard metadata.durationMs != nil else { return "couldn't read the file's length" }
        let guess = await contentAnalyzer?.analyze(
            filePath: track.filePath, title: metadata.title, artist: metadata.artist, album: metadata.album
        )
        do {
            try trackStore.applyTags(
                id: track.id,
                title: guess?.title ?? metadata.title,
                durationMs: metadata.durationMs, year: metadata.year,
                artistName: guess?.artist ?? metadata.artist, albumName: guess?.album ?? metadata.album
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func hasChanged(_ known: TrackFile, _ file: CloudFile) -> Bool {
        if let newHash = file.contentHash {
            return newHash != known.contentHash
        }
        if let newModifiedAt = file.modifiedAt, let oldModifiedAt = known.remoteModifiedAt {
            return newModifiedAt != oldModifiedAt
        }
        return known.sizeBytes != file.sizeBytes
    }

    private func extractMetadata(provider: CloudProvider, fileID: String) async -> (title: String?, artist: String?, album: String?, durationMs: Int?, year: Int?) {
        guard let url = try? await provider.streamURL(forFileID: fileID) else {
            return (nil, nil, nil, nil, nil)
        }
        return await extractMetadata(url: url)
    }

    private func extractMetadata(url: URL) async -> (title: String?, artist: String?, album: String?, durationMs: Int?, year: Int?) {
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
