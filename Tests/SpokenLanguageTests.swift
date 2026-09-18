import XCTest
@testable import EarToListen

/// The rule for "which recognizer transcribes this?": the most specific answer wins.
/// Language belongs to the recording, not the person — a Mandarin speaker gives a talk in
/// English, and one speaker's albums are often in different languages.
final class SpokenLanguageTests: XCTestCase {
    private func makeTrack(language: String?) -> Track {
        Track(
            id: "t1", providerID: "p1", artistID: "a1", albumID: "al1", filePath: "ep.mp3",
            title: "ep", trackNumber: nil, durationMs: nil, sizeBytes: nil, isLost: false,
            language: language, updatedAt: Date()
        )
    }

    private func makeAlbum(language: String?) -> Album {
        Album(id: "al1", artistID: "a1", name: "Season 3", language: language)
    }

    private func makeArtist(language: String?) -> Artist {
        Artist(id: "a1", name: "Speaker", language: language)
    }

    func testTheEpisodeOutranksItsAlbumAndSpeaker() {
        let resolved = TranscriptRunner.resolveLanguage(
            track: makeTrack(language: "en-US"),
            album: makeAlbum(language: "zh-CN"),
            artist: makeArtist(language: "zh-CN")
        )
        XCTAssertEqual(resolved?.identifier, "en-US")
        XCTAssertEqual(resolved?.source, .episode)
    }

    func testTheAlbumOutranksItsSpeaker() {
        let resolved = TranscriptRunner.resolveLanguage(
            track: makeTrack(language: nil),
            album: makeAlbum(language: "en-US"),
            artist: makeArtist(language: "zh-CN")
        )
        XCTAssertEqual(resolved?.identifier, "en-US")
        XCTAssertEqual(resolved?.source, .album)
    }

    func testItFallsBackToTheSpeaker() {
        let resolved = TranscriptRunner.resolveLanguage(
            track: makeTrack(language: nil), album: makeAlbum(language: nil), artist: makeArtist(language: "zh-CN")
        )
        XCTAssertEqual(resolved?.identifier, "zh-CN")
        XCTAssertEqual(resolved?.source, .speaker)
    }

    /// Nobody has said, so nothing is claimed — the caller falls back to the app-wide
    /// choice rather than guessing from the phone.
    func testNoAnswerAnywhereResolvesToNothing() {
        XCTAssertNil(TranscriptRunner.resolveLanguage(
            track: makeTrack(language: nil), album: makeAlbum(language: nil), artist: makeArtist(language: nil)
        ))
    }
}
