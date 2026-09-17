import Foundation
import GRDB

struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "tracks"

    var id: String
    var providerID: String
    var artistID: String?
    var albumID: String?
    var showID: String? = nil
    var filePath: String
    var title: String
    var trackNumber: Int?
    var durationMs: Int?
    /// Release year, read from embedded metadata where available (used for "Browse by Year").
    var year: Int? = nil
    var sizeBytes: Int64? = nil
    /// Provider-supplied content fingerprint as of the last sync (e.g. S3's ETag) — lets
    /// a same-path, same-size overwrite still be detected without downloading the file.
    var contentHash: String? = nil
    var remoteModifiedAt: Date? = nil
    /// True when the last sync no longer found this file in the bucket listing.
    var isLost: Bool = false
    var updatedAt: Date
    /// Free-text episode notes — only ever written by hand or from an AI suggestion the
    /// listener accepted, never from embedded tags.
    var notes: String? = nil
    /// Filename under `ImageFileStore.artwork`, not a full path, so it survives
    /// reinstalls and travels as-is in a `LibrarySnapshot` backup.
    var artworkFileName: String? = nil
    /// Set when the listener saves `EpisodeEditView`. Their title beats the embedded tag
    /// from then on — tags get re-read only for files the library doesn't know yet.
    var metadataEditedAt: Date? = nil
    /// Playback progress, in milliseconds, as of `lastPlayedAt`.
    var positionMs: Int? = nil
    var lastPlayedAt: Date? = nil
}
