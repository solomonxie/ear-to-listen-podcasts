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

    /// The profile fields are `nil`-means-leave-alone rather than `nil`-means-clear: the
    /// page saves every field on every focus change, and an AI pass writes only the ones
    /// it had something to say about.
    func updateArtist(
        id: String, name: String, bio: String?, language: String? = nil,
        knownFor: String?? = nil, background: String?? = nil, profile: String?? = nil,
        link: String?? = nil
    ) throws {
        let old: Artist? = try dbQueue.write { db in
            guard var artist = try Artist.fetchOne(db, key: id) else { return nil }
            let old = artist
            artist.name = name
            artist.bio = bio
            artist.language = language
            if let knownFor { artist.knownFor = knownFor }
            if let background { artist.background = background }
            if let profile { artist.profile = profile }
            if let link { artist.link = link }
            try artist.update(db)
            return old
        }
        guard let old else { return }
        ChangeLog.record(
            "speakers", key: name, old: old,
            new: [
                "name": name, "bio": bio, "language": language,
                "knownFor": knownFor ?? old.knownFor, "background": background ?? old.background,
                "profile": profile ?? old.profile, "link": link ?? old.link,
            ],
            in: dbQueue
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
    /// Detaches an album (and its episodes) from whoever it was credited to. The speaker
    /// row itself stays — they may front other albums, and deleting a page because one
    /// album stopped pointing at it isn't what "None" means here.
    func clearAlbumArtist(albumID: String) throws {
        try dbQueue.write { db in
            guard var album = try Album.fetchOne(db, key: albumID) else { return }
            album.artistID = nil
            try album.update(db)
            try db.execute(sql: "UPDATE tracks SET artistID = NULL WHERE albumID = ?", arguments: [albumID])
        }
    }

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

    /// `profile` is `nil`-means-leave-alone, for the same reason as `updateArtist`'s.
    func updateAlbum(
        id: String, name: String, notes: String?, artworkFileName: String?, year: Int? = nil,
        profile: String?? = nil
    ) throws {
        try dbQueue.write { db in
            guard var album = try Album.fetchOne(db, key: id) else { return }
            album.name = name
            album.notes = notes
            album.artworkFileName = artworkFileName
            album.year = year
            if let profile { album.profile = profile }
            album.metadataEditedAt = Date()
            try album.update(db)
        }
    }

    func album(id: String) throws -> Album? {
        try dbQueue.read { db in try Album.fetchOne(db, key: id) }
    }

    // MARK: Topics

    func upsertTopic(name: String) throws -> Topic {
        try dbQueue.write { db in
            if let existing = try Topic.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let topic = Topic(id: UUID().uuidString, name: name)
            try topic.insert(db)
            return topic
        }
    }

    func topics() throws -> [Topic] {
        try dbQueue.read { db in try Topic.order(Column("name")).fetchAll(db) }
    }

    func linkAlbumTopic(albumID: String, topicID: String) throws {
        try dbQueue.write { db in try AlbumTopic(albumID: albumID, topicID: topicID).save(db) }
    }

    func unlinkAlbumTopic(albumID: String, topicID: String) throws {
        try dbQueue.write { db in
            try AlbumTopic.filter(Column("albumID") == albumID && Column("topicID") == topicID).deleteAll(db)
        }
    }

    func topics(forAlbum albumID: String) throws -> [Topic] {
        try dbQueue.read { db in
            try Topic.fetchAll(db, sql: """
                SELECT topics.* FROM topics
                JOIN albumTopics ON albumTopics.topicID = topics.id
                WHERE albumTopics.albumID = ?
                ORDER BY topics.name
                """, arguments: [albumID])
        }
    }

    func albumIDs(forTopic topicID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT albumID FROM albumTopics WHERE topicID = ?", arguments: [topicID]))
        }
    }

    /// Replaces an album's tags in one go — what the album page's topic editor saves, and
    /// what an accepted AI suggestion writes.
    func setTopics(_ names: [String], forAlbum albumID: String) throws {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let topics = try cleaned.map { try upsertTopic(name: $0) }
        try dbQueue.write { db in
            try AlbumTopic.filter(Column("albumID") == albumID).deleteAll(db)
            for topic in topics {
                try AlbumTopic(albumID: albumID, topicID: topic.id).save(db)
            }
        }
    }
}
