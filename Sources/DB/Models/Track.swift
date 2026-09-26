import Foundation
import GRDB

struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "tracks"

    var id: String
    var providerID: String
    var artistID: String?
    var albumID: String?
    var filePath: String
    var title: String
    var trackNumber: Int?
    var durationMs: Int?
    /// Release year, read from embedded metadata where available (used for "Browse by Year").
    var year: Int? = nil
    var sizeBytes: Int64? = nil
    /// Provider-supplied content fingerprint as of the last sync (e.g. S3's ETag) — lets
    /// a same-path, same-size overwrite still be detected without downloading the file.
    var contentHash: String?
    /// The transcript file beside this episode in its bucket, as of the last sync. Nil
    /// means the last listing had none — not "not looked at yet".
    var transcriptPath: String? = nil
    var remoteModifiedAt: Date? = nil
    /// True when the last sync no longer found this file in the bucket listing.
    var isLost: Bool = false
    /// BCP-47 identifier for the language of this episode, overriding its album and its
    /// speaker. The last word on what recognizer to use, because it's the only level
    /// where someone can have heard the audio.
    var language: String? = nil
    var updatedAt: Date
    /// Free-text episode notes — only ever written by hand or from an AI suggestion the
    /// listener accepted, never from embedded tags.
    var notes: String? = nil
    /// What the episode says, in a few lines: written by the AI pass over the transcript
    /// or typed by hand, and editable either way. `[mm:ss]` markers in it are jumpable —
    /// see `EpisodeSummary`.
    var summary: String? = nil
    /// Filename under `ImageFileStore.artwork`, not a full path, so it survives
    /// reinstalls and travels as-is in a `LibrarySnapshot` backup.
    var artworkFileName: String? = nil
    /// The title this episode had before `DuplicateTitles` numbered it apart from one it
    /// collided with — the receipt that makes the numbering reversible. Nil for every
    /// title the app never renamed, including one that genuinely ends in "(2)".
    var numberedFrom: String? = nil
    /// Set when the listener saves `EpisodeEditView`. Their title beats the embedded tag
    /// from then on — tags get re-read only for files the library doesn't know yet.
    var metadataEditedAt: Date? = nil
    /// Playback progress, in milliseconds, as of `lastPlayedAt`.
    var positionMs: Int? = nil
    var lastPlayedAt: Date? = nil
    /// Marked by hand from the player. Says nothing about how often it's played — that's
    /// what `lastPlayedAt` is for — only that the listener wants it findable.
    var isFavorite: Bool = false
    /// Put aside to hear soon. The other half of favouriting: a favourite is what you
    /// keep after listening, this is what you line up before.
    var listenLater: Bool = false
    /// What says this episode and another one are the same recording, however they're
    /// named and whichever bucket each came out of — see `FileFingerprint`. Nil when the
    /// file didn't give enough to be sure, which means it is never folded with anything.
    /// Every place the file lives is a `TrackFile`; the pair above is the one it plays.
    var fingerprint: String? = nil
}
