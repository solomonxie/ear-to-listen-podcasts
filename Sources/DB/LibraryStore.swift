import Foundation
import GRDB

struct LibraryStore {
    let dbQueue: DatabaseQueue

    func upsertArtist(name: String) throws -> Artist {
        try dbQueue.write { db in
            if let existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let artist = Artist(id: UUID().uuidString, name: name)
            try artist.insert(db)
            return artist
        }
    }

    func upsertAlbum(name: String, artistID: String?) throws -> Album {
        try dbQueue.write { db in
            if let existing = try Album.filter(Column("name") == name && Column("artistID") == artistID).fetchOne(db) {
                return existing
            }
            let album = Album(id: UUID().uuidString, artistID: artistID, name: name)
            try album.insert(db)
            return album
        }
    }

    func artists() throws -> [Artist] {
        try dbQueue.read { db in try Artist.order(Column("name")).fetchAll(db) }
    }

    func albums(forArtist artistID: String?) throws -> [Album] {
        try dbQueue.read { db in
            try Album.filter(Column("artistID") == artistID).order(Column("name")).fetchAll(db)
        }
    }
}
