import Foundation
import GRDB

struct PlaylistStore {
    let dbQueue: DatabaseQueue

    func create(_ playlist: Playlist) throws {
        try dbQueue.write { db in try playlist.insert(db) }
    }

    func rename(id: String, to name: String) throws {
        try dbQueue.write { db in
            if var playlist = try Playlist.fetchOne(db, key: id) {
                playlist.name = name
                try playlist.update(db)
            }
        }
    }

    func delete(id: String) throws {
        try dbQueue.write { db in _ = try Playlist.deleteOne(db, key: id) }
    }

    func all() throws -> [Playlist] {
        try dbQueue.read { db in try Playlist.order(Column("createdAt")).fetchAll(db) }
    }

    func addTrack(_ trackID: String, toPlaylist playlistID: String, at position: Int) throws {
        try dbQueue.write { db in
            try PlaylistTrack(playlistID: playlistID, trackID: trackID, position: position).save(db)
        }
    }

    func removeTrack(_ trackID: String, fromPlaylist playlistID: String) throws {
        try dbQueue.write { db in
            try PlaylistTrack
                .filter(Column("playlistID") == playlistID && Column("trackID") == trackID)
                .deleteAll(db)
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
