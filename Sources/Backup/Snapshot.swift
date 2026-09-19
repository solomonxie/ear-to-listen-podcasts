import Foundation

/// Portable, secrets-free snapshot of a user's app data for manual export/import
/// and remote backup/restore. Covers playlists, the provider/import-source list,
/// transcripts and their corrections, and any speaker or episode edits (bio/photo,
/// retitled episodes/artwork — a `LibrarySnapshot` file is a zip bundling this JSON with
/// the referenced images, see `BackupService.archive`); excludes everything else
/// library-side (rebuilt by `SyncEngine`), the episode audio itself (already sitting in
/// the bucket), and credentials (stay in Keychain — re-enter them after restoring on a
/// new device).
struct LibrarySnapshot: Codable {
    /// v2 added `transcripts`; v3 added favourites and bookmarks to each episode. Older
    /// files still decode — every field added after v1 defaults rather than demanding a key.
    static let currentVersion = 3

    /// Identifies a track by (providerID, filePath) rather than its local DB id,
    /// since that id is a fresh UUID per device/install — stable across a resync,
    /// not across a fresh one.
    struct TrackRef: Codable {
        var providerID: String
        var filePath: String
        var title: String
        var position: Int
    }

    struct PlaylistEntry: Codable {
        var id: String
        var name: String
        var source: String
        var createdAt: Date
        var tracks: [TrackRef]
    }

    struct ProviderEntry: Codable {
        var id: String
        var type: String
        var label: String
        var isActive: Bool
        var syncFrequencyMinutes: Int?
        var createdAt: Date
    }

    struct ImportSourceEntry: Codable {
        var id: String
        var type: String
        var label: String
        var createdAt: Date
    }

    /// Keyed by name rather than id — matches how `LibraryStore.upsertArtist(name:)` finds
    /// a speaker synced back onto a fresh device, since the local id is a new UUID there.
    /// Only speakers with a manual edit are included; plain synced-metadata ones aren't.
    struct ArtistEntry: Codable {
        var name: String
        var bio: String?
        /// BCP-47, e.g. `zh-CN`. Hand-set and not re-derivable, so it travels.
        var language: String?
        /// References an entry under `photos/` in the same zip archive, not a device path.
        var photoFileName: String?
    }

    /// One hand-edited episode, keyed by (providerID, filePath) like `TrackRef` — the
    /// local id is a fresh UUID per install. Speaker and album travel by name so they
    /// re-link against whatever those rows are called on the restoring device. Only
    /// episodes someone actually edited are included; the rest is synced metadata
    /// `SyncEngine` rebuilds by itself.
    struct EpisodeEntry: Codable {
        /// A moment the listener marked, and whatever they typed against it. Hand-made
        /// and unrecoverable, so it travels with the episode it belongs to.
        struct BookmarkEntry: Codable {
            var positionMs: Int
            var note: String?
            var tags: String?
            var transcriptText: String?
            var createdAt: Date
        }

        var providerID: String
        var filePath: String
        var title: String
        var artistName: String?
        var albumName: String?
        var year: Int?
        var trackNumber: Int?
        var notes: String?
        /// References an entry under `artwork/` in the same zip archive, not a device path.
        var artworkFileName: String?
        var isFavorite: Bool = false
        var bookmarks: [BookmarkEntry] = []
        /// Nil for an episode that travels only for its favourite/bookmarks — nobody
        /// edited its details.
        var editedAt: Date?

        /// Hand-written for the same reason `LibrarySnapshot`'s is: a synthesized decoder
        /// demands every key, so an archive written before favourites and bookmarks
        /// existed would fail to decode instead of restoring what it does have.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerID = try container.decode(String.self, forKey: .providerID)
            filePath = try container.decode(String.self, forKey: .filePath)
            title = try container.decode(String.self, forKey: .title)
            artistName = try container.decodeIfPresent(String.self, forKey: .artistName)
            albumName = try container.decodeIfPresent(String.self, forKey: .albumName)
            year = try container.decodeIfPresent(Int.self, forKey: .year)
            trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
            notes = try container.decodeIfPresent(String.self, forKey: .notes)
            artworkFileName = try container.decodeIfPresent(String.self, forKey: .artworkFileName)
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            bookmarks = try container.decodeIfPresent([BookmarkEntry].self, forKey: .bookmarks) ?? []
            editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        }

        init(
            providerID: String, filePath: String, title: String, artistName: String?, albumName: String?,
            year: Int?, trackNumber: Int?, notes: String?, artworkFileName: String?,
            isFavorite: Bool = false, bookmarks: [BookmarkEntry] = [], editedAt: Date?
        ) {
            self.providerID = providerID
            self.filePath = filePath
            self.title = title
            self.artistName = artistName
            self.albumName = albumName
            self.year = year
            self.trackNumber = trackNumber
            self.notes = notes
            self.artworkFileName = artworkFileName
            self.isFavorite = isFavorite
            self.bookmarks = bookmarks
            self.editedAt = editedAt
        }
    }

    /// A transcript and the corrections made to it, keyed by (providerID, filePath) like
    /// `TrackRef`. Worth carrying even though it's machine-derived: re-transcribing an
    /// episode costs either an hour of battery or real money, and the corrections are
    /// hand-typed and can't be regenerated at all.
    struct TranscriptEntry: Codable {
        struct EditEntry: Codable {
            var id: String
            var segmentStart: Double
            var originalText: String
            var editedText: String
            var createdAt: Date
        }

        var providerID: String
        var filePath: String
        var segments: [TranscriptSegment]
        var edits: [EditEntry] = []
        var engine: String?
        var updatedAt: Date?
    }

    var version: Int = currentVersion
    var exportedAt: Date
    var playlists: [PlaylistEntry]
    var providers: [ProviderEntry]
    var importSources: [ImportSourceEntry]
    var artists: [ArtistEntry] = []
    var episodes: [EpisodeEntry] = []
    var transcripts: [TranscriptEntry] = []

    init(
        exportedAt: Date,
        playlists: [PlaylistEntry],
        providers: [ProviderEntry],
        importSources: [ImportSourceEntry],
        artists: [ArtistEntry] = [],
        episodes: [EpisodeEntry] = [],
        transcripts: [TranscriptEntry] = []
    ) {
        self.exportedAt = exportedAt
        self.playlists = playlists
        self.providers = providers
        self.importSources = importSources
        self.artists = artists
        self.episodes = episodes
        self.transcripts = transcripts
    }

    /// Written by hand because a synthesized `init(from:)` ignores a property's default
    /// value and demands the key — which made every field added after v1 (`artists`,
    /// `episodes`, now `transcripts`) a hard requirement, so an older archive failed to
    /// decode at all instead of restoring what it does have.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        playlists = try container.decodeIfPresent([PlaylistEntry].self, forKey: .playlists) ?? []
        providers = try container.decodeIfPresent([ProviderEntry].self, forKey: .providers) ?? []
        importSources = try container.decodeIfPresent([ImportSourceEntry].self, forKey: .importSources) ?? []
        artists = try container.decodeIfPresent([ArtistEntry].self, forKey: .artists) ?? []
        episodes = try container.decodeIfPresent([EpisodeEntry].self, forKey: .episodes) ?? []
        transcripts = try container.decodeIfPresent([TranscriptEntry].self, forKey: .transcripts) ?? []
    }
}
