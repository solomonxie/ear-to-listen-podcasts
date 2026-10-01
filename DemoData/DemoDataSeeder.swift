import Foundation
import GRDB

/// Writes the sample library in `demo-library.json` into a database — speakers, shows,
/// episodes with progress and listened state, transcripts timed to the bundled audio
/// (`demo-timings.json`, from `make-audio.py`), summaries, bookmarks, terms and playlists.
/// Only ever into the dataset `DemoMode` swaps in, never over the listener's own.
enum DemoDataSeeder {
    static func seed(into dbQueue: DatabaseQueue, now: Date = Date()) throws {
        let library = try decode(Library.self, from: "demo-library")
        let timings = try decode([String: Timing].self, from: "demo-timings")
        let days: (Int?) -> Date? = { $0.map { now.addingTimeInterval(-Double($0) * 86_400 - 3_600) } }

        let provider = ProviderRecord(
            id: UUID().uuidString, type: DemoProvider.providerType, label: "Sample Library",
            configJSON: "", isActive: false, createdAt: now, lastSyncedAt: now
        )
        let artists = Dictionary(uniqueKeysWithValues: library.speakers.map { speaker in
            (speaker.key, Artist(
                id: UUID().uuidString, name: speaker.name, bio: speaker.bio, knownFor: speaker.knownFor,
                background: speaker.background, link: speaker.link, isDemo: true
            ))
        })
        let topics = Dictionary(uniqueKeysWithValues: library.topics.map {
            ($0, Topic(id: UUID().uuidString, name: $0, isDemo: true))
        })

        var tracks: [String: Track] = [:]
        try dbQueue.write { db in
            try provider.insert(db)
            for artist in artists.values { try artist.insert(db) }
            for topic in topics.values { try topic.insert(db) }
        }

        let trackStore = TrackStore(dbQueue: dbQueue)
        let transcriptStore = TranscriptStore(dbQueue: dbQueue)
        let termStore = TermStore(dbQueue: dbQueue)

        for seed in library.albums {
            let speaker = artists[seed.speaker]
            let album = Album(
                id: UUID().uuidString, artistID: speaker?.id, name: seed.name, notes: seed.notes,
                profile: seed.profile, year: seed.year, language: seed.language, isDemo: true
            )
            try dbQueue.write { db in
                try album.insert(db)
                for name in seed.topics {
                    guard let topic = topics[name] else { continue }
                    try AlbumTopic(albumID: album.id, topicID: topic.id).insert(db)
                }
            }

            for episode in seed.episodes {
                guard let timing = timings[episode.key] else { continue }
                let starts = timing.lines.map(\.start)
                let artist = episode.speaker.flatMap { artists[$0] } ?? speaker
                let track = Track(
                    id: UUID().uuidString, providerID: provider.id, artistID: artist?.id, albumID: album.id,
                    filePath: DemoProvider.fileName(for: episode.key), title: episode.title,
                    trackNumber: episode.number, durationMs: timing.durationMs, year: seed.year,
                    sizeBytes: timing.sizeBytes, contentHash: nil, language: seed.language,
                    updatedAt: now, notes: episode.notes,
                    summary: episode.summary.map { fillMarkers($0, starts: starts) },
                    metadataEditedAt: now,
                    positionMs: episode.progress.map { Int(Double(timing.durationMs) * min($0, 0.99)) },
                    lastPlayedAt: days(episode.playedDaysAgo),
                    isFavorite: episode.favorite ?? false,
                    listenLater: episode.listenLater ?? false,
                    listenedAt: episode.listened == true ? days(episode.playedDaysAgo) : nil
                )
                try trackStore.upsert(track, artistName: artist?.name, albumName: album.name)
                tracks[episode.key] = track

                let texts = episode.lines.map { $0.count > 1 ? $0[1] : "" }
                try transcriptStore.save(trackID: track.id, segments: zip(timing.lines, texts).map {
                    TranscriptSegment(start: $0.start, end: $0.end, text: $1)
                })

                let spoken = texts.joined(separator: " ").lowercased()
                let mentions = (episode.terms ?? []).reduce(into: [String: Int]()) { counts, term in
                    counts[term] = max(1, spoken.components(separatedBy: term.lowercased()).count - 1)
                }
                if !mentions.isEmpty { try termStore.setTerms(mentions, forTrack: track.id) }

                try dbQueue.write { db in
                    for mark in episode.bookmarks ?? [] where timing.lines.indices.contains(mark.line) {
                        try Bookmark(
                            id: UUID().uuidString, trackID: track.id,
                            positionMs: Int(timing.lines[mark.line].start * 1000),
                            note: mark.note, tags: mark.tags, transcriptText: texts[mark.line],
                            createdAt: days(mark.daysAgo) ?? now
                        ).insert(db)
                    }
                }
            }
        }

        try dbQueue.write { db in
            for (index, seed) in library.playlists.enumerated() {
                let playlist = Playlist(
                    id: UUID().uuidString, name: seed.name, source: "local",
                    createdAt: now.addingTimeInterval(-Double(index) * 86_400), isDemo: true
                )
                try playlist.insert(db)
                for (position, key) in seed.episodes.compactMap({ tracks[$0]?.id }).enumerated() {
                    try PlaylistTrack(playlistID: playlist.id, trackID: key, position: position).insert(db)
                }
            }
        }
    }

    /// `{3}` → `[0:21]`, the start of transcript line 3 — so the summary's times follow the
    /// audio whenever `make-audio.py` regenerates it.
    static func fillMarkers(_ text: String, starts: [Double]) -> String {
        var result = text
        for (index, start) in starts.enumerated().reversed() {
            result = result.replacingOccurrences(of: "{\(index)}", with: EpisodeSummary.marker(for: start))
        }
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    struct Library: Decodable {
        var speakers: [Speaker]
        var topics: [String]
        var albums: [AlbumSeed]
        var playlists: [PlaylistSeed]
    }

    struct Speaker: Decodable {
        var key: String
        var name: String
        var bio: String?
        var knownFor: String?
        var background: String?
        var link: String?
    }

    struct AlbumSeed: Decodable {
        var key: String
        var name: String
        var speaker: String
        var year: Int?
        var language: String?
        var topics: [String]
        var notes: String?
        var profile: String?
        var episodes: [EpisodeSeed]
    }

    struct EpisodeSeed: Decodable {
        var key: String
        var number: Int?
        var title: String
        var speaker: String?
        var progress: Double?
        var listened: Bool?
        var playedDaysAgo: Int?
        var favorite: Bool?
        var listenLater: Bool?
        var notes: String?
        /// `[speakerKey, text]` per line.
        var lines: [[String]]
        var summary: String?
        var terms: [String]?
        var bookmarks: [BookmarkSeed]?
    }

    struct BookmarkSeed: Decodable {
        var line: Int
        var note: String?
        var tags: String?
        var daysAgo: Int?
    }

    struct PlaylistSeed: Decodable {
        var name: String
        var episodes: [String]
    }

    struct Timing: Decodable {
        struct Line: Decodable {
            var start: Double
            var end: Double
        }
        var durationMs: Int
        var sizeBytes: Int64
        var lines: [Line]
    }
}
