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
        Track(id: id, providerID: YouTubeVideo.providerID, artistID: artist, albumID: album, filePath: video, title: title, updatedAt: Date())
    }

    func testEntriesPutTheTranscriptUnderSpeakerAndAlbum() {
        let entries = YouTubeCatalog.entries(
            [track("e1", video: "dQw4w9WgXcQ", title: "Grace / Truth")],
            speakers: ["s1": "Tim Keller"], albums: ["a1": "Sermons"], root: "audio/"
        )
        XCTAssertEqual(entries.first?.transcriptPath, "audio/Tim Keller/Sermons/Grace - Truth [dQw4w9WgXcQ].vtt")
        XCTAssertEqual(entries.first?.url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testUnfiledEpisodesUseTheDefaultAlbum() {
        let entries = YouTubeCatalog.entries(
            [track("e1", video: "dQw4w9WgXcQ", title: "T", artist: nil, album: nil)], speakers: [:], albums: [:], root: nil
        )
        XCTAssertEqual(entries.first?.transcriptPath, "YouTube/YouTube's YouTube Podcasts/T [dQw4w9WgXcQ].vtt")
    }

    func testTranscriptsAreFoundByTheVideoIDInTheirName() {
        let listing = ["a/b/T [dQw4w9WgXcQ].zh-Hans.vtt", "a/b/T [dQw4w9WgXcQ].vtt", "a/b/ep1.vtt", "x/[jNQXAC9IVRw].srt"]
            .map { CloudFile(id: $0, name: ($0 as NSString).lastPathComponent, path: $0) }
        let found = YouTubeTranscripts.byVideoID(in: listing)
        XCTAssertEqual(found["dQw4w9WgXcQ"], ["a/b/T [dQw4w9WgXcQ].vtt", "a/b/T [dQw4w9WgXcQ].zh-Hans.vtt"])
        XCTAssertEqual(found["jNQXAC9IVRw"], ["x/[jNQXAC9IVRw].srt"])
        XCTAssertEqual(found.count, 2)
    }
}
