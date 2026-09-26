import Foundation
import GRDB

/// One place an episode's audio actually is. Most episodes have one; an episode has
/// several when the same file turns up in another bucket, or under another name in the
/// same one — see `FileFingerprint` for what "the same file" means.
///
/// The episode keeps one of these on `tracks` itself, as `providerID`/`filePath`:
/// playback, the cache and the browser each need *a* file to open, and they all work in
/// that pair. This table is the whole set, and it's what a sync pass keeps up to date —
/// whether each copy is still there, what it weighs, and which transcript sits beside it.
struct TrackFile: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "trackFiles"

    var id: String
    var trackID: String
    var providerID: String
    var filePath: String
    var sizeBytes: Int64? = nil
    var contentHash: String? = nil
    /// The transcript beside *this* copy. Two copies in two buckets can each have their
    /// own, and an upload writes over every one of them.
    var transcriptPath: String? = nil
    var remoteModifiedAt: Date? = nil
    /// True when the last sync of this copy's source no longer listed it. The episode is
    /// only lost once every copy is.
    var isLost: Bool = false
    var addedAt: Date

    init(
        id: String = UUID().uuidString, trackID: String, providerID: String, filePath: String,
        sizeBytes: Int64? = nil, contentHash: String? = nil, transcriptPath: String? = nil,
        remoteModifiedAt: Date? = nil, isLost: Bool = false, addedAt: Date = Date()
    ) {
        self.id = id
        self.trackID = trackID
        self.providerID = providerID
        self.filePath = filePath
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
        self.transcriptPath = transcriptPath
        self.remoteModifiedAt = remoteModifiedAt
        self.isLost = isLost
        self.addedAt = addedAt
    }

    /// The copy an episode row is currently pointed at.
    init(primaryOf track: Track) {
        self.init(
            trackID: track.id, providerID: track.providerID, filePath: track.filePath,
            sizeBytes: track.sizeBytes, contentHash: track.contentHash,
            transcriptPath: track.transcriptPath, remoteModifiedAt: track.remoteModifiedAt,
            isLost: track.isLost
        )
    }
}
