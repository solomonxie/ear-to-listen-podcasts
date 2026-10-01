import Foundation
import GRDB

/// Artwork as plain image files beside the audio, the same way transcripts are
/// (`docs/design/bucket-layout.md`): `ep-01.jpg` for an episode, `cover.jpg` in the folder
/// for an album — the names Plex, Jellyfin and Kodi already read.
///
/// **Up** whenever a picture is set here: it's a deliberate act on that one item.
/// **Down** from the sync listing, only for something with no picture that nobody has
/// edited — removing a picture stamps the edit, so it isn't pulled straight back.
enum ArtworkSidecar {
    static let imageExtensions = ["jpg", "jpeg", "png"]
    /// In preference order.
    static let folderCoverStems = ["cover", "folder", "album", "front"]
    static let albumCoverName = "cover.jpg"

    /// What one listing holds: audio path → its image, folder → its cover.
    struct Found: Sendable, Equatable {
        var episodes: [String: String] = [:]
        var folders: [String: String] = [:]
    }

    static func episodePath(forAudioPath path: String) -> String? {
        TranscriptFile.sidecarPath(forAudioPath: path, extension: "jpg")
    }

    /// `show/2026/ep-01.mp3` → `show/2026`, `ep.mp3` → "".
    static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func coverPath(inFolder folder: String) -> String {
        folder.isEmpty ? albumCoverName : "\(folder)/\(albumCoverName)"
    }

    static func find(in files: [CloudFile]) -> Found {
        var images: [String: String] = [:]
        var covers: [String: (rank: Int, path: String)] = [:]
        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let stem = (file.path as NSString).deletingPathExtension
            if images[stem] == nil || ext == "jpg" { images[stem] = file.path }
            let name = (stem as NSString).lastPathComponent.lowercased()
            if let rank = folderCoverStems.firstIndex(of: name) {
                let folder = folder(of: file.path)
                if (covers[folder]?.rank ?? .max) > rank { covers[folder] = (rank, file.path) }
            }
        }
        var found = Found(folders: covers.mapValues(\.path))
        for file in files where FileKind(path: file.path).isPlayable {
            if let image = images[(file.path as NSString).deletingPathExtension] {
                found.episodes[file.path] = image
            }
        }
        return found
    }

    /// The folders that are this album's alone: every live copy in them belongs to it.
    /// A folder shared with another album gets no `cover.jpg`, since it would be the
    /// other album's cover too.
    static func ownedFolders(
        of albumID: String, copies: [(providerID: String, filePath: String, albumID: String?)]
    ) -> [(providerID: String, folder: String)] {
        var owners: [String: [String: Set<String?>]] = [:]
        for copy in copies {
            owners[copy.providerID, default: [:]][folder(of: copy.filePath), default: []].insert(copy.albumID)
        }
        return owners.flatMap { provider, folders in
            folders.filter { $0.value == [albumID] }.map { (provider, $0.key) }
        }.sorted { ($0.providerID, $0.folder) < ($1.providerID, $1.folder) }
    }

    // MARK: Up

    static func uploadEpisode(_ fileName: String, trackID: String, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) async {
        guard let data = imageData(fileName) else { return }
        let copies = (try? TrackFileStore(dbQueue: dbQueue).all(forTrack: trackID)) ?? []
        for copy in copies where !copy.isLost {
            guard let path = episodePath(forAudioPath: copy.filePath) else { continue }
            await write(data, to: path, providerID: copy.providerID, dbQueue: dbQueue)
        }
    }

    static func uploadAlbum(_ fileName: String, albumID: String, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) async {
        guard let data = imageData(fileName) else { return }
        let copies = (try? liveCopies(sharingProvidersWith: albumID, dbQueue: dbQueue)) ?? []
        for owned in ownedFolders(of: albumID, copies: copies) {
            await write(data, to: coverPath(inFolder: owned.folder), providerID: owned.providerID, dbQueue: dbQueue)
        }
    }

    /// Read-only sources and failed writes are skipped: the picture is safe here and in
    /// the backup, and nothing about it is worth an alert.
    private static func write(_ data: Data, to path: String, providerID: String, dbQueue: DatabaseQueue) async {
        guard let provider = provider(providerID, dbQueue: dbQueue), provider.isWritable else { return }
        try? await provider.upload(data, toPath: path, contentType: "image/jpeg")
    }

    // MARK: Down

    /// After a listing. `onlyPath` narrows it to one just-imported file.
    static func adopt(
        _ found: Found, providerID: String, provider: CloudProvider, onlyPath: String? = nil,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) async {
        guard !found.episodes.isEmpty || !found.folders.isEmpty else { return }
        let copies = (try? liveCopies(ofProvider: providerID, dbQueue: dbQueue)) ?? []
        let scoped = onlyPath.map { path in copies.filter { $0.filePath == path } } ?? copies

        var adopted = false
        for copy in scoped {
            guard let image = found.episodes[copy.filePath],
                  let track = try? await dbQueue.read({ try Track.fetchOne($0, key: copy.trackID) }),
                  track.artworkFileName == nil, track.metadataEditedAt == nil,
                  let fileName = await fetch(image, provider: provider) else { continue }
            try? await dbQueue.write { db in
                try db.execute(sql: "UPDATE tracks SET artworkFileName = ? WHERE id = ? AND artworkFileName IS NULL",
                               arguments: [fileName, copy.trackID])
            }
            adopted = true
        }

        var albumsByFolder: [String: Set<String?>] = [:]
        for copy in copies { albumsByFolder[folder(of: copy.filePath), default: []].insert(copy.albumID) }
        for folder in Set(scoped.map { folder(of: $0.filePath) }) {
            guard let cover = found.folders[folder],
                  let owners = albumsByFolder[folder], owners.count == 1, let albumID = owners.first ?? nil,
                  let album = try? await dbQueue.read({ try Album.fetchOne($0, key: albumID) }),
                  album.artworkFileName == nil, album.metadataEditedAt == nil,
                  let fileName = await fetch(cover, provider: provider) else { continue }
            try? await dbQueue.write { db in
                try db.execute(sql: "UPDATE albums SET artworkFileName = ? WHERE id = ? AND artworkFileName IS NULL",
                               arguments: [fileName, albumID])
            }
            adopted = true
        }
        if adopted { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
    }

    /// The last listing per source, so an episode imported from the queue afterwards can
    /// take its picture without listing again.
    static func remember(_ found: Found, providerID: String) {
        lock.withLock { lastFound[providerID] = found }
    }

    static func remembered(providerID: String) -> Found? {
        lock.withLock { lastFound[providerID] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastFound: [String: Found] = [:]

    // MARK: Plumbing

    private static func imageData(_ fileName: String) -> Data? {
        ImageFileStore.artwork.url(for: fileName).flatMap { try? Data(contentsOf: $0) }
    }

    private static func fetch(_ path: String, provider: CloudProvider) async -> String? {
        guard let data = try? await provider.download(fileID: path) else { return nil }
        return try? await ImageFileStore.artwork.save(data, maxDimension: 800)
    }

    private static func provider(_ id: String, dbQueue: DatabaseQueue) -> CloudProvider? {
        guard let record = try? dbQueue.read({ try ProviderRecord.fetchOne($0, key: id) }) else { return nil }
        return try? ProviderManager.shared.provider(for: record)
    }

    private struct Copy: FetchableRecord, Decodable {
        var trackID: String
        var providerID: String
        var filePath: String
        var albumID: String?
    }

    private static func liveCopies(ofProvider providerID: String, dbQueue: DatabaseQueue) throws -> [Copy] {
        try dbQueue.read { db in
            try Copy.fetchAll(db, sql: """
                SELECT trackFiles.trackID, trackFiles.providerID, trackFiles.filePath, tracks.albumID
                FROM trackFiles JOIN tracks ON tracks.id = trackFiles.trackID
                WHERE trackFiles.providerID = ? AND trackFiles.isLost = 0
                """, arguments: [providerID])
        }
    }

    private static func liveCopies(
        sharingProvidersWith albumID: String, dbQueue: DatabaseQueue
    ) throws -> [(providerID: String, filePath: String, albumID: String?)] {
        try dbQueue.read { db in
            try Copy.fetchAll(db, sql: """
                SELECT trackFiles.trackID, trackFiles.providerID, trackFiles.filePath, tracks.albumID
                FROM trackFiles JOIN tracks ON tracks.id = trackFiles.trackID
                WHERE trackFiles.isLost = 0 AND trackFiles.providerID IN (
                    SELECT trackFiles.providerID FROM trackFiles
                    JOIN tracks ON tracks.id = trackFiles.trackID WHERE tracks.albumID = ?)
                """, arguments: [albumID])
        }.map { ($0.providerID, $0.filePath, $0.albumID) }
    }
}
