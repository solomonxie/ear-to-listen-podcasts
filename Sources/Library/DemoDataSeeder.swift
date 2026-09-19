import Foundation
import GRDB

extension Notification.Name {
    /// Posted after the library's real DB content changes in a way that isn't already
    /// covered by a targeted refresh — demo data reset/reseed, and (from
    /// `SyncEngine.importFileIfNeeded`) each newly-synced file — so Home's shelves
    /// (including newly-appearing speakers) update live instead of waiting for the
    /// next full view reload.
    static let libraryDidChange = Notification.Name("libraryDidChange")

    /// Posted whenever a bookmark is added or removed. Bookmarks show in four places at
    /// once — the player's button, Now Playing's list, the album page and Home — and none
    /// of them owns the others.
    static let bookmarksDidChange = Notification.Name("bookmarksDidChange")

    /// Posted once by `SyncEngine.sync(providerRecord:)` when a listing pass has queued
    /// its files. It's the wake-up as well as the refresh: `SyncQueueManager` both
    /// republishes its state and starts draining on it, so a pass running off the main
    /// actor doesn't need to know whether the loop is already alive.
    static let syncQueueDidChange = Notification.Name("syncQueueDidChange")
}

/// Populates the real DB (not a parallel mock store) with a small sample library — a
/// few speakers, topics, albums, playlists, and the three bundled demo clips as
/// actual synced-look `Track`s — for someone who wants to look around before connecting
/// anything. Everything it writes is tagged `isDemo = true` (the provider row is
/// `DemoProvider.providerType`), so it can be wiped and reseeded without touching
/// anything the user actually synced.
///
/// Never seeded automatically. A fresh install is an empty library, because content the
/// user didn't put there is indistinguishable from content they did once it's sitting in
/// the same shelves — they'd have to work out which of it is real.
enum DemoDataSeeder {
    static var isLoaded: Bool {
        let count = try? DatabaseManager.shared.dbQueue.read { db in
            try ProviderRecord.filter(Column("type") == DemoProvider.providerType).fetchCount(db)
        }
        return (count ?? 0) > 0
    }

    /// Loads the sample library, replacing any copy of it already there — the same call
    /// backs both "load it" and "put it back the way it was".
    static func load() throws {
        try clear()
        try seed()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Wipes the sample library without putting it back — once real sources are connected
    /// the demo rows are just clutter in every shelf.
    static func removeAll() throws {
        try clear()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    static func clear() throws {
        try DatabaseManager.shared.dbQueue.write { db in
            // Cascades to the demo tracks, their transcripts, and any queued sync jobs.
            try ProviderRecord.filter(Column("type") == DemoProvider.providerType).deleteAll(db)

            try db.execute(sql: "DELETE FROM playlistTracks WHERE playlistID IN (SELECT id FROM playlists WHERE isDemo = 1)")
            try Playlist.filter(Column("isDemo") == true).deleteAll(db)
            try db.execute(sql: "DELETE FROM albumTopics WHERE albumID IN (SELECT id FROM albums WHERE isDemo = 1)")
            try Topic.filter(Column("isDemo") == true).deleteAll(db)
            try Album.filter(Column("isDemo") == true).deleteAll(db)
            try Artist.filter(Column("isDemo") == true).deleteAll(db)
        }
    }

    private static func seed() throws {
        let dbQueue = DatabaseManager.shared.dbQueue

        let provider = ProviderRecord(
            id: UUID().uuidString, type: DemoProvider.providerType, label: "Demo Content",
            configJSON: "{}", isActive: false, createdAt: Date()
        )

        let alex = Artist(id: UUID().uuidString, name: "Alex Chen", bio: "Co-host of Deep Dive, covering on-device AI and developer tools.", isDemo: true)
        let priya = Artist(id: UUID().uuidString, name: "Priya Rao", bio: "Co-host of Deep Dive; explores how AI changes everyday tools.", isDemo: true)
        let jordan = Artist(id: UUID().uuidString, name: "Jordan Lee", bio: "Host of Retrospective, a weekly history show.", isDemo: true)
        let casey = Artist(id: UUID().uuidString, name: "Casey Kim", bio: "Host of Daily Brief, a short daily news rundown.", isDemo: true)

        let technology = Topic(id: UUID().uuidString, name: "Technology", isDemo: true)
        let ai = Topic(id: UUID().uuidString, name: "AI", isDemo: true)
        let history = Topic(id: UUID().uuidString, name: "History", isDemo: true)
        let news = Topic(id: UUID().uuidString, name: "News", isDemo: true)

        let bestOf = Album(id: UUID().uuidString, artistID: nil, name: "Best of Demo", isDemo: true)
        let origins = Album(id: UUID().uuidString, artistID: jordan.id, name: "Origins", isDemo: true)

        let techTrack = Track(
            id: UUID().uuidString, providerID: provider.id, artistID: alex.id, albumID: bestOf.id,
            filePath: "ep-tech-1", title: "On-Device AI, For Real This Time",
            trackNumber: nil, durationMs: nil, year: 2024, updatedAt: Date()
        )
        let historyTrack = Track(
            id: UUID().uuidString, providerID: provider.id, artistID: jordan.id, albumID: origins.id,
            filePath: "ep-history-1", title: "A Short History of the Podcast",
            trackNumber: nil, durationMs: nil, year: 2023, updatedAt: Date()
        )
        let newsTrack = Track(
            id: UUID().uuidString, providerID: provider.id, artistID: casey.id, albumID: bestOf.id,
            filePath: "ep-news-1", title: "Local-First Is Having a Moment",
            trackNumber: nil, durationMs: nil, year: 2024, updatedAt: Date()
        )

        let commuteMix = Playlist(id: UUID().uuidString, name: "Commute Mix", source: "local", createdAt: Date(), isDemo: true)
        let weekendLongform = Playlist(id: UUID().uuidString, name: "Weekend Longform", source: "local", createdAt: Date(), isDemo: true)

        try dbQueue.write { db in
            try provider.insert(db)
            for artist in [alex, priya, jordan, casey] { try artist.insert(db) }
            for topic in [technology, ai, history, news] { try topic.insert(db) }
            for album in [bestOf, origins] { try album.insert(db) }
            // Topics tag collections now, so the demo library shows them doing that.
            try AlbumTopic(albumID: bestOf.id, topicID: technology.id).insert(db)
            try AlbumTopic(albumID: bestOf.id, topicID: ai.id).insert(db)
            try AlbumTopic(albumID: bestOf.id, topicID: news.id).insert(db)
            try AlbumTopic(albumID: origins.id, topicID: history.id).insert(db)
            for track in [techTrack, historyTrack, newsTrack] { try track.insert(db) }
            for playlist in [commuteMix, weekendLongform] { try playlist.insert(db) }
            try PlaylistTrack(playlistID: commuteMix.id, trackID: techTrack.id, position: 0).insert(db)
            try PlaylistTrack(playlistID: commuteMix.id, trackID: newsTrack.id, position: 1).insert(db)
            try PlaylistTrack(playlistID: weekendLongform.id, trackID: historyTrack.id, position: 0).insert(db)
        }

        let transcriptStore = TranscriptStore(dbQueue: dbQueue)
        try transcriptStore.save(trackID: techTrack.id, segments: [
            TranscriptSegment(start: 0.00, text: "Alex Chen: Welcome back to Deep Dive. I'm Alex Chen."),
            TranscriptSegment(start: 3.43, text: "Priya Rao: And I'm Priya Rao. Today we're talking about on-device AI."),
            TranscriptSegment(start: 7.22, text: "Alex Chen: The big shift is models small enough to run locally, so nothing leaves your phone."),
            TranscriptSegment(start: 12.52, text: "Priya Rao: Which matters a lot once you're piping in personal data, like a podcast library."),
            TranscriptSegment(start: 17.07, text: "Alex Chen: Exactly. That's the whole idea behind Ear to Listen Podcasts. Your files, your metadata, your device."),
            TranscriptSegment(start: 25.69, text: "Priya Rao: Alright, that's our show for today. Thanks for listening."),
        ])
        try transcriptStore.save(trackID: historyTrack.id, segments: [
            TranscriptSegment(start: 0.00, text: "Jordan Lee: This is Retrospective. I'm Jordan Lee."),
            TranscriptSegment(start: 3.11, text: "Jordan Lee: This week: the history of the podcast format."),
            TranscriptSegment(start: 7.33, text: "Jordan Lee: It really started with RSS feeds in the early 2000s, before anyone called it a podcast."),
            TranscriptSegment(start: 14.19, text: "Jordan Lee: The name itself is a mashup of iPod and broadcast, which feels almost quaint now."),
            TranscriptSegment(start: 22.60, text: "Jordan Lee: That's it for today. See you next week."),
        ])
        try transcriptStore.save(trackID: newsTrack.id, segments: [
            TranscriptSegment(start: 0.00, text: "Casey Kim: You're listening to Daily Brief. I'm Casey Kim."),
            TranscriptSegment(start: 2.74, text: "Casey Kim: Today's top story: local-first apps are having a moment."),
            TranscriptSegment(start: 6.08, text: "Casey Kim: More people want their data to live on their own storage, not a vendor's server."),
            TranscriptSegment(start: 10.19, text: "Casey Kim: That's a wrap for today's brief."),
        ])
    }
}
