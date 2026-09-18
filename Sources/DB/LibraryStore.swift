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

    func artist(id: String) throws -> Artist? {
        try dbQueue.read { db in try Artist.fetchOne(db, key: id) }
    }

    func updateArtist(id: String, name: String, bio: String?, language: String? = nil) throws {
        let old: Artist? = try dbQueue.write { db in
            guard var artist = try Artist.fetchOne(db, key: id) else { return nil }
            let old = artist
            artist.name = name
            artist.bio = bio
            artist.language = language
            try artist.update(db)
            return old
        }
        guard let old else { return }
        ChangeLog.record(
            "speakers", key: name, old: old,
            new: ["name": name, "bio": bio, "language": language], in: dbQueue
        )
    }

    func updateArtistPhoto(id: String, photoFileName: String?) throws {
        let old: Artist? = try dbQueue.write { db in
            guard var artist = try Artist.fetchOne(db, key: id) else { return nil }
            let old = artist
            artist.photoFileName = photoFileName
            try artist.update(db)
            return old
        }
        guard let old else { return }
        ChangeLog.record(
            "speakers", key: old.name, old: ["photoFileName": old.photoFileName],
            new: ["photoFileName": photoFileName], in: dbQueue
        )
    }

    func albums(forArtist artistID: String?) throws -> [Album] {
        try dbQueue.read { db in
            try Album.filter(Column("artistID") == artistID).order(Column("name")).fetchAll(db)
        }
    }

    func albums() throws -> [Album] {
        try dbQueue.read { db in try Album.order(Column("name")).fetchAll(db) }
    }

    /// Corrects an album's speaker when the embedded/guessed metadata was wrong (e.g. a
    /// shared uploader/collection name instead of the actual speaker) — repoints the
    /// album and every one of its tracks at `artistName` (creating that artist if it
    /// doesn't exist yet), rather than just the album, since tracks carry their own
    /// denormalized `artistID` too.
    @discardableResult
    func reassignAlbumArtist(albumID: String, artistName: String) throws -> Artist {
        try dbQueue.write { db in
            let artist: Artist
            if let existing = try Artist.filter(Column("name") == artistName).fetchOne(db) {
                artist = existing
            } else {
                artist = Artist(id: UUID().uuidString, name: artistName)
                try artist.insert(db)
            }
            guard var album = try Album.fetchOne(db, key: albumID) else { return artist }
            album.artistID = artist.id
            try album.update(db)
            try db.execute(
                sql: "UPDATE tracks SET artistID = ? WHERE albumID = ?",
                arguments: [artist.id, albumID]
            )
            return artist
        }
    }

    /// The hand-edited fields (name/notes/artwork), stamped as edited so nothing
    /// re-derives over them. Speaker isn't here — it lives on the tracks too, so it goes
    /// through `reassignAlbumArtist`.
    func updateAlbumLanguage(id: String, language: String?) throws {
        try dbQueue.write { db in
            guard var album = try Album.fetchOne(db, key: id) else { return }
            album.language = language
            try album.update(db)
        }
    }

    func updateAlbum(id: String, name: String, notes: String?, artworkFileName: String?, year: Int? = nil) throws {
        try dbQueue.write { db in
            guard var album = try Album.fetchOne(db, key: id) else { return }
            album.name = name
            album.notes = notes
            album.artworkFileName = artworkFileName
            album.year = year
            album.metadataEditedAt = Date()
            try album.update(db)
        }
    }

    func album(id: String) throws -> Album? {
        try dbQueue.read { db in try Album.fetchOne(db, key: id) }
    }

    // MARK: Shows

    func upsertShow(name: String, summary: String? = nil, isDemo: Bool = false) throws -> Show {
        try dbQueue.write { db in
            if let existing = try Show.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let show = Show(id: UUID().uuidString, name: name, summary: summary, isDemo: isDemo, createdAt: Date())
            try show.insert(db)
            return show
        }
    }

    func shows() throws -> [Show] {
        try dbQueue.read { db in try Show.order(Column("name")).fetchAll(db) }
    }

    func show(id: String) throws -> Show? {
        try dbQueue.read { db in try Show.fetchOne(db, key: id) }
    }

    func savedShows() throws -> [Show] {
        try dbQueue.read { db in try Show.filter(Column("isSaved") == true).order(Column("name")).fetchAll(db) }
    }

    func setShow(_ showID: String, saved: Bool) throws {
        try dbQueue.write { db in
            guard var show = try Show.fetchOne(db, key: showID) else { return }
            show.isSaved = saved
            try show.update(db)
        }
    }

    func linkShowArtist(showID: String, artistID: String) throws {
        try dbQueue.write { db in try ShowArtist(showID: showID, artistID: artistID).save(db) }
    }

    func artists(forShow showID: String) throws -> [Artist] {
        try dbQueue.read { db in
            try Artist.fetchAll(db, sql: """
                SELECT artists.* FROM artists
                JOIN showArtists ON showArtists.artistID = artists.id
                WHERE showArtists.showID = ?
                ORDER BY artists.name
                """, arguments: [showID])
        }
    }

    func shows(forArtist artistID: String) throws -> [Show] {
        try dbQueue.read { db in
            try Show.fetchAll(db, sql: """
                SELECT shows.* FROM shows
                JOIN showArtists ON showArtists.showID = shows.id
                WHERE showArtists.artistID = ?
                ORDER BY shows.name
                """, arguments: [artistID])
        }
    }

    // MARK: Topics

    func upsertTopic(name: String, isDemo: Bool = false) throws -> Topic {
        try dbQueue.write { db in
            if let existing = try Topic.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let topic = Topic(id: UUID().uuidString, name: name, isDemo: isDemo)
            try topic.insert(db)
            return topic
        }
    }

    func topics() throws -> [Topic] {
        try dbQueue.read { db in try Topic.order(Column("name")).fetchAll(db) }
    }

    func linkShowTopic(showID: String, topicID: String) throws {
        try dbQueue.write { db in try ShowTopic(showID: showID, topicID: topicID).save(db) }
    }

    func topics(forShow showID: String) throws -> [Topic] {
        try dbQueue.read { db in
            try Topic.fetchAll(db, sql: """
                SELECT topics.* FROM topics
                JOIN showTopics ON showTopics.topicID = topics.id
                WHERE showTopics.showID = ?
                ORDER BY topics.name
                """, arguments: [showID])
        }
    }

    func shows(forTopic topicID: String) throws -> [Show] {
        try dbQueue.read { db in
            try Show.fetchAll(db, sql: """
                SELECT shows.* FROM shows
                JOIN showTopics ON showTopics.showID = shows.id
                WHERE showTopics.topicID = ?
                ORDER BY shows.name
                """, arguments: [topicID])
        }
    }
}
