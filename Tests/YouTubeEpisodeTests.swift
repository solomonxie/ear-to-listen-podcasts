import GRDB
import XCTest
@testable import EarToListen

final class YouTubeVideoTests: XCTestCase {
    func testReadsTheIDOutOfEveryLinkShape() {
        let id = "dQw4w9WgXcQ"
        for link in [
            id,
            "https://www.youtube.com/watch?v=\(id)&t=42s",
            "https://m.youtube.com/watch?feature=share&v=\(id)",
            "youtu.be/\(id)?si=abc",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)?feature=share",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "  https://music.youtube.com/watch?v=\(id)  ",
        ] {
            XCTAssertEqual(YouTubeVideo.id(from: link), id, link)
        }
    }

    func testRejectsWhatIsNotAVideo() {
        for link in ["", "https://vimeo.com/123", "https://www.youtube.com/@channel", "https://youtu.be/short", "dQw4w9WgXc!"] {
            XCTAssertNil(YouTubeVideo.id(from: link), link)
        }
    }

    func testWatchLinkCarriesTheMoment() {
        XCTAssertEqual(YouTubeVideo.watchURL(id: "dQw4w9WgXcQ", at: 83.9).absoluteString, "https://youtu.be/dQw4w9WgXcQ?t=83")
        XCTAssertEqual(YouTubeVideo.watchURL(id: "dQw4w9WgXcQ").absoluteString, "https://youtu.be/dQw4w9WgXcQ")
    }

    func testTypedLengths() {
        XCTAssertEqual(AddYouTubeEpisodeView.seconds(in: "1:02:30"), 3750)
        XCTAssertEqual(AddYouTubeEpisodeView.seconds(in: "62:30"), 3750)
        XCTAssertEqual(AddYouTubeEpisodeView.seconds(in: "45"), 2700)
        XCTAssertNil(AddYouTubeEpisodeView.seconds(in: ""))
        XCTAssertNil(AddYouTubeEpisodeView.seconds(in: "abc"))
    }
}

final class TimestampedTextTests: XCTestCase {
    func testTimestampOnItsOwnLineThenWords() {
        let segments = TimestampedText.parse("""
            0:00
            welcome back everyone
            0:04
            4 seconds
            today we're talking about
            grace
            1:02:03
            the end
            """)
        XCTAssertEqual(segments.map(\.start), [0, 4, 3723])
        XCTAssertEqual(segments.map(\.text), ["welcome back everyone", "today we're talking about grace", "the end"])
        XCTAssertEqual(segments[0].end, 4)
    }

    func testTimestampAndWordsOnOneLine() {
        let segments = TimestampedText.parse("0:01 hello\n0:05 world")
        XCTAssertEqual(segments.map(\.start), [1, 5])
        XCTAssertEqual(segments.map(\.text), ["hello", "world"])
    }

    func testTextBeforeTheFirstTimestampIsDropped() {
        XCTAssertEqual(TimestampedText.parse("Transcript\n0:10\nhi").map(\.text), ["hi"])
    }

    func testSubtitleFilesStillParse() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nhello\n"
        XCTAssertEqual(TimestampedText.parse(srt).first?.text, "hello")
    }

    func testNothingTimedIsNothing() {
        XCTAssertTrue(TimestampedText.parse("just some words").isEmpty)
    }

    func testSavedYouTubeTranscriptAsTxtKeepsItsTimes() {
        let segments = TranscriptRunner.segments(in: "0:00\nhi\n0:07\nthere", extension: "txt", duration: 600)
        XCTAssertEqual(segments.map(\.start), [0, 7])
    }

    func testUntimedTxtIsSpreadAcrossTheEpisode() {
        let segments = TranscriptRunner.segments(in: "One. Two.", extension: "txt", duration: 100)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.last?.end, 100)
    }
}

final class YouTubeFilingTests: XCTestCase {
    func testBlankAlbumIsTheSpeakersYouTubePodcasts() {
        let filed = YouTubeEpisodes.filing(speaker: "Tim Keller", album: "  ")
        XCTAssertEqual(filed.speaker, "Tim Keller")
        XCTAssertEqual(filed.album, "Tim Keller's YouTube Podcasts")
    }

    func testNoSpeakerFallsBackToYouTube() {
        XCTAssertEqual(YouTubeEpisodes.filing(speaker: nil, album: nil).album, "YouTube's YouTube Podcasts")
    }

    func testAChosenAlbumIsKept() {
        XCTAssertEqual(YouTubeEpisodes.filing(speaker: "A", album: "Sermons").album, "Sermons")
    }
}

final class YouTubeCatalogTests: XCTestCase {
    private func track(_ id: String, video: String, title: String, artist: String? = "s1", album: String? = "a1") -> Track {
        Track(
            id: id, providerID: YouTubeVideo.providerID, artistID: artist, albumID: album, filePath: video, title: title,
            updatedAt: Date(), youTubeVideoID: video
        )
    }

    func testEntriesPutTheTranscriptUnderSpeakerAndAlbum() {
        let entries = YouTubeCatalog.entries(
            [track("e1", video: "dQw4w9WgXcQ", title: "Grace / Truth")],
            speakers: ["s1": "Tim Keller"], albums: ["a1": "Sermons"], root: "audio/"
        )
        XCTAssertEqual(entries.first?.transcriptPath, "audio/tim-keller/sermons/dQw4w9WgXcQ-grace-truth.vtt")
        XCTAssertEqual(entries.first?.url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(entries.first?.audioPath, "audio/tim-keller/sermons/dQw4w9WgXcQ-grace-truth.mp3")
    }

    func testUnfiledEpisodesUseTheDefaultAlbum() {
        let entries = YouTubeCatalog.entries(
            [track("e1", video: "dQw4w9WgXcQ", title: "T", artist: nil, album: nil)], speakers: [:], albums: [:], root: nil
        )
        XCTAssertEqual(entries.first?.transcriptPath, "youtube/youtube-s-youtube-podcasts/dQw4w9WgXcQ-t.vtt")
    }

    func testTranscriptsAreFoundByTheVideoIDInTheirName() {
        let listing = [
            "a/b/dQw4w9WgXcQ-old-title.zh-Hans.vtt", "a/b/dQw4w9WgXcQ-renamed.vtt", "a/b/episode-01-intro.vtt",
            "x/jNQXAC9IVRw.srt", "a/b/dQw4w9WgXcQ-renamed.mp3",
        ].map { CloudFile(id: $0, name: ($0 as NSString).lastPathComponent, path: $0) }
        let found = YouTubeTranscripts.byVideoID(in: listing)
        XCTAssertEqual(found["dQw4w9WgXcQ"], ["a/b/dQw4w9WgXcQ-renamed.vtt", "a/b/dQw4w9WgXcQ-old-title.zh-Hans.vtt"])
        XCTAssertEqual(found["jNQXAC9IVRw"], ["x/jNQXAC9IVRw.srt"])
        XCTAssertEqual(found.count, 2)
    }
}

final class YouTubeAudioFileTests: XCTestCase {
    private func setUp(_ dbQueue: DatabaseQueue) throws -> TrackStore {
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "p1", configJSON: "", isActive: true, createdAt: Date())
        )
        let store = TrackStore(dbQueue: dbQueue)
        var video = Track(
            id: "e1", providerID: YouTubeVideo.providerID, filePath: "dQw4w9WgXcQ", title: "Grace", updatedAt: Date()
        )
        video.youTubeVideoID = "dQw4w9WgXcQ"
        try store.upsert(video, artistName: nil, albumName: nil)
        return store
    }

    func testTheIDIsReadFromTheFileName() {
        XCTAssertEqual(YouTubeVideo.id(inFileName: "a/b/dQw4w9WgXcQ-grace.mp3"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeVideo.id(inFileName: "a/b/dQw4w9WgXcQ.m4a"), "dQw4w9WgXcQ")
        XCTAssertNil(YouTubeVideo.id(inFileName: "a/dQw4w9WgXcQ/ep1.mp3"))
        XCTAssertNil(YouTubeVideo.id(inFileName: "a/b/episode-01-intro.mp3"), "a normal name isn't an ID")
        XCTAssertNil(YouTubeVideo.id(inFileName: "a/b/my podcast!-ep.mp3"))
    }

    func testSlugsAreSafeAndKeepEveryScript() {
        XCTAssertEqual(YouTubeVideo.slug("  Grace & Truth: Part 2! "), "grace-truth-part-2")
        XCTAssertEqual(YouTubeVideo.slug("恩典与真理 (上)"), "恩典与真理-上")
        XCTAssertEqual(YouTubeVideo.slug("..."), "")
    }

    func testAnAudioFilePlaysInsteadOfTheVideoAndTheVideoComesBackWhenItGoes() throws {
        let dbQueue = try DatabaseQueue()
        let store = try setUp(dbQueue)
        try store.attach(
            TrackFile(trackID: "e1", providerID: "p1", filePath: "a/dQw4w9WgXcQ-grace.mp3", sizeBytes: 1_000),
            toYouTubeEpisode: "e1"
        )
        var episode = try XCTUnwrap(store.find(id: "e1"))
        XCTAssertFalse(episode.isVideoOnly)
        XCTAssertEqual(episode.filePath, "a/dQw4w9WgXcQ-grace.mp3")
        XCTAssertEqual(episode.youTubeID, "dQw4w9WgXcQ")
        XCTAssertEqual(try store.youTubeEpisodes().map(\.id), ["e1"])

        _ = try store.markLost(providerID: "p1", keepingPaths: [])
        episode = try XCTUnwrap(store.find(id: "e1"))
        XCTAssertTrue(episode.isVideoOnly)
        XCTAssertFalse(episode.isLost)
    }
}
