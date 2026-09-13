import AVFoundation
import Foundation

private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"]

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
    let dbQueue = DatabaseManager.shared.dbQueue
    private var trackStore: TrackStore { TrackStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }
    private let contentAnalyzer = ContentAnalyzer()

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
    func sync(providerRecord record: ProviderRecord) async throws -> SyncResult {
        guard NetworkMonitor.shared.isConnected else { throw SyncEngineError.offline }
        let provider = try ProviderManager.shared.provider(for: record)
        let files = try await provider.listFiles(inFolder: nil)
            .filter { audioExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }

        var seenPaths: Set<String> = []
        var added = 0
        for file in files {
            seenPaths.insert(file.path)

            if let existing = try trackStore.find(providerID: record.id, filePath: file.path) {
                if existing.isLost || existing.sizeBytes != file.sizeBytes {
                    try trackStore.refresh(id: existing.id, sizeBytes: file.sizeBytes, isLost: false)
                }
                continue
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
                sizeBytes: file.sizeBytes,
                isLost: false,
                updatedAt: Date()
            )
            try trackStore.upsert(track, artistName: artistName, albumName: albumName)
            added += 1
        }

        let lost = try trackStore.markLost(providerID: record.id, keepingPaths: seenPaths)
        try providerStore.updateLastSynced(id: record.id, at: Date())

        return SyncResult(added: added, lost: lost, totalFiles: files.count)
    }

    private func extractMetadata(provider: CloudProvider, fileID: String) async -> (title: String?, artist: String?, album: String?, durationMs: Int?) {
        guard let url = try? await provider.streamURL(forFileID: fileID) else {
            return (nil, nil, nil, nil)
        }
        let asset = AVURLAsset(url: url)
        guard let commonMetadata = try? await asset.load(.commonMetadata) else {
            return (nil, nil, nil, nil)
        }

        var title: String?
        var artist: String?
        var album: String?
        for item in commonMetadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: title = try? await item.load(.stringValue)
            case .commonKeyArtist: artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: album = try? await item.load(.stringValue)
            default: break
            }
        }

        let durationSeconds = try? await asset.load(.duration).seconds
        let durationMs = durationSeconds.map { Int($0 * 1000) }
        return (title, artist, album, durationMs)
    }
}
