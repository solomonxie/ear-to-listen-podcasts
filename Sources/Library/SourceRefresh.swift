import Foundation
import GRDB

/// The one place a file's ETag and tags are asked for again on purpose: a button on an
/// episode or album page. Sync never does this per file — the listing already carries them.
struct SourceRefresh {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) { self.dbQueue = dbQueue }

    /// Re-reads each file's ETag/size/date from its source, then queues a fresh tag read.
    /// Returns failures as "title: reason".
    func refresh(trackIDs: [String]) async -> [String] {
        let trackStore = TrackStore(dbQueue: dbQueue)
        let copies = TrackFileStore(dbQueue: dbQueue)
        let records = Dictionary(
            ((try? ProviderStore(dbQueue: dbQueue).all()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
        )
        var failures: [String] = []
        var refreshed: [String] = []
        for id in trackIDs {
            guard let track = try? trackStore.find(id: id), let record = records[track.providerID],
                  let copy = try? copies.find(providerID: track.providerID, filePath: track.filePath) else { continue }
            do {
                let provider = try ProviderManager.shared.provider(for: record)
                let latest = try await provider.metadata(forFileID: track.filePath)
                try trackStore.refreshCopy(
                    copy, sizeBytes: latest.sizeBytes,
                    contentHash: latest.contentHash?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                    remoteModifiedAt: latest.modifiedAt
                )
                refreshed.append(id)
            } catch {
                failures.append("\(track.title): \(describeCloudError(error))")
            }
        }
        try? trackStore.markNeedsTags(ids: refreshed)
        NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return failures
    }
}
