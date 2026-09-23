import Foundation
import GRDB

struct PlaylistStore {
    let dbQueue: DatabaseQueue

    func create(_ playlist: Playlist) throws {
        try dbQueue.write { db in try playlist.insert(db) }
        ChangeLog.record("playlists", key: playlist.id, new: playlist, in: dbQueue)
    }

    func rename(id: String, to name: String) throws {
        let old: String? = try dbQueue.write { db in
            guard var playlist = try Playlist.fetchOne(db, key: id) else { return nil }
            let old = playlist.name
            playlist.name = name
            try playlist.update(db)
            return old
        }
        guard let old else { return }
        ChangeLog.record("playlists", key: id, old: ["name": old], new: ["name": name], in: dbQueue)
    }

    func delete(id: String) throws {
        let old: Playlist? = try dbQueue.write { db in
            let old = try Playlist.fetchOne(db, key: id)
            _ = try Playlist.deleteOne(db, key: id)
            return old
        }
        ChangeLog.record("playlists", key: id, old: old, in: dbQueue)
    }

    func all() throws -> [Playlist] {
        try dbQueue.read { db in try Playlist.order(Column("createdAt")).fetchAll(db) }
    }

    func addTrack(_ trackID: String, toPlaylist playlistID: String, at position: Int) throws {
        try dbQueue.write { db in
            try PlaylistTrack(playlistID: playlistID, trackID: trackID, position: position).save(db)
        }
        ChangeLog.record(
            "playlistTracks", key: "\(playlistID)/\(trackID)",
            new: ["position": position], in: dbQueue
        )
    }

    func removeTrack(_ trackID: String, fromPlaylist playlistID: String) throws {
        let old: Int? = try dbQueue.write { db in
            let old = try PlaylistTrack
                .filter(Column("playlistID") == playlistID && Column("trackID") == trackID)
                .fetchOne(db)?.position
            try PlaylistTrack
                .filter(Column("playlistID") == playlistID && Column("trackID") == trackID)
                .deleteAll(db)
            return old
        }
        ChangeLog.record(
            "playlistTracks", key: "\(playlistID)/\(trackID)",
            old: old.map { ["position": $0] }, in: dbQueue
        )
    }

    /// Every playlist this episode is on — what the episode page's Playlists row shows.
    /// The reverse of `tracks(inPlaylist:)`, and the direction anyone looking at one
    /// episode is asking in.
    func playlists(containingTrack trackID: String) throws -> [Playlist] {
        try dbQueue.read { db in
            try Playlist.fetchAll(db, sql: """
                SELECT playlists.* FROM playlists
                JOIN playlistTracks ON playlistTracks.playlistID = playlists.id
                WHERE playlistTracks.trackID = ?
                ORDER BY playlists.createdAt
                """, arguments: [trackID])
        }
    }

    func tracks(inPlaylist playlistID: String) throws -> [Track] {
        try dbQueue.read { db in
            try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                JOIN playlistTracks ON playlistTracks.trackID = tracks.id
                WHERE playlistTracks.playlistID = ?
                ORDER BY playlistTracks.position
                """, arguments: [playlistID])
        }
    }
}
