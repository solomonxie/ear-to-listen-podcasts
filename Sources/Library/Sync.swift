import AVFoundation
import Foundation

private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"]

struct SyncEngine {
    let dbQueue = DatabaseManager.shared.dbQueue
    private var trackStore: TrackStore { TrackStore(dbQueue: dbQueue) }
    private var libraryStore: LibraryStore { LibraryStore(dbQueue: dbQueue) }
    private var providerStore: ProviderStore { ProviderStore(dbQueue: dbQueue) }

    /// Syncs every active provider's file listing into the local library.
    /// Returns the number of tracks added or updated.
    func syncActiveProviders() async throws -> Int {
        var total = 0
        for record in try providerStore.active() {
            total += try await sync(providerRecord: record)
        }
        return total
    }

    func sync(providerRecord record: ProviderRecord) async throws -> Int {
        let provider = try ProviderManager.shared.provider(for: record)
        let files = try await provider.listFiles(inFolder: nil)
            .filter { audioExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }

        var count = 0
        for file in files {
            let metadata = await extractMetadata(provider: provider, fileID: file.path)
            let title = metadata.title ?? (file.name as NSString).deletingPathExtension
            let artist = try metadata.artist.map { try libraryStore.upsertArtist(name: $0) }
            let album = try metadata.album.map { albumName in
                try libraryStore.upsertAlbum(name: albumName, artistID: artist?.id)
            }

            let existing = try trackStore.find(providerID: record.id, filePath: file.path)
            let track = Track(
                id: existing?.id ?? UUID().uuidString,
                providerID: record.id,
                artistID: artist?.id,
                albumID: album?.id,
                filePath: file.path,
                title: title,
                trackNumber: nil,
                durationMs: metadata.durationMs,
                updatedAt: Date()
            )
            try trackStore.upsert(track, artistName: metadata.artist, albumName: metadata.album)
            count += 1
        }
        return count
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
