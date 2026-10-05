import Foundation
import GRDB

/// Deleting for good: the local entry and the file behind it, in every bucket that holds
/// a copy. Neglecting (`TrackStore.setNeglected`) is the reversible alternative.
struct EpisodeRemoval {
    struct Result {
        var deleted = 0
        /// Episodes kept because a copy couldn't be removed from its source, with why.
        var failures: [String] = []
    }

    let trackStore: TrackStore
    let trackFileStore: TrackFileStore
    let providerStore: ProviderStore

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        trackStore = TrackStore(dbQueue: dbQueue)
        trackFileStore = TrackFileStore(dbQueue: dbQueue)
        providerStore = ProviderStore(dbQueue: dbQueue)
    }

    /// An episode is only removed locally once every live copy is gone remotely, so a
    /// failure never leaves an entry-less file the library would re-import.
    func delete(trackIDs: [String]) async -> Result {
        var result = Result()
        let records = Dictionary(
            ((try? providerStore.all()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        for id in trackIDs {
            guard let track = try? trackStore.find(id: id) else { continue }
            let copies = ((try? trackFileStore.all(forTrack: id)) ?? []).filter { !$0.isLost }
            do {
                for copy in copies {
                    guard let record = records[copy.providerID] else { continue }
                    let provider = try ProviderManager.shared.provider(for: record)
                    try await provider.deleteFile(atPath: copy.filePath)
                    for sidecar in copy.transcriptPaths ?? [] {
                        try? await provider.deleteFile(atPath: sidecar)
                    }
                }
                try trackStore.delete(id: id)
                result.deleted += 1
            } catch {
                result.failures.append("\(track.title): \(error.localizedDescription)")
            }
        }
        if result.deleted > 0 { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
        return result
    }

    func deleteAlbum(id: String, libraryStore: LibraryStore) async -> Result {
        let ids = (try? trackStore.trackIDs(albumID: id)) ?? []
        let result = await delete(trackIDs: ids)
        if result.failures.isEmpty { try? libraryStore.deleteAlbum(id: id) }
        return result
    }

    func deleteArtist(id: String, libraryStore: LibraryStore) async -> Result {
        let albums = (try? libraryStore.allAlbums(forArtist: id)) ?? []
        let ids = (try? trackStore.trackIDs(artistID: id)) ?? []
        let result = await delete(trackIDs: ids)
        if result.failures.isEmpty {
            for album in albums { try? libraryStore.deleteAlbum(id: album.id) }
            try? libraryStore.deleteArtist(id: id)
        }
        return result
    }
}
