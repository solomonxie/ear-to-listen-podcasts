import XCTest
@testable import EarToListen

/// `ep1.zh.vtt` beside `ep1.mp3` is a Chinese transcript of that episode, not a transcript
/// of an episode called "ep1.zh" that doesn't exist — and `show.part.vtt` is not in Part.
final class TranscriptLanguageTests: XCTestCase {
    private func file(_ path: String) -> CloudFile {
        CloudFile(id: path, name: (path as NSString).lastPathComponent, path: path, sizeBytes: 1, mimeType: nil, modifiedAt: nil)
    }

    func testLanguageTagsAreReadFromTheName() {
        XCTAssertEqual(TranscriptFile.language(ofSidecar: "show/ep1.zh.vtt"), "zh")
        XCTAssertEqual(TranscriptFile.language(ofSidecar: "show/ep1.zh-CN.srt"), "zh-CN")
        XCTAssertEqual(TranscriptFile.language(ofSidecar: "show/ep1.pt_BR.vtt"), "pt-BR")
        XCTAssertNil(TranscriptFile.language(ofSidecar: "show/ep1.vtt"))
        XCTAssertNil(TranscriptFile.language(ofSidecar: "show/talk.part.vtt"))
        XCTAssertNil(TranscriptFile.language(ofSidecar: "show/ep.01.vtt"))
    }

    func testEveryLanguageIsPairedWithItsEpisodeUntaggedFirst() {
        let found = TranscriptFile.sidecarSetsByAudioPath(in: [
            file("show/ep1.mp3"), file("show/ep1.zh.vtt"), file("show/ep1.en.srt"),
            file("show/ep1.en.vtt"), file("show/ep1.vtt"), file("show/ep2.mp3"),
        ])

        XCTAssertEqual(found["show/ep1.mp3"], ["show/ep1.vtt", "show/ep1.en.vtt", "show/ep1.zh.vtt"])
        XCTAssertNil(found["show/ep2.mp3"])
        XCTAssertEqual(TranscriptFile.sidecarsByAudioPath(in: [file("show/ep1.mp3"), file("show/ep1.zh.vtt")]),
                       ["show/ep1.mp3": "show/ep1.zh.vtt"])
    }

    /// The exact basename belongs to the audio that has it, whatever the last word looks like.
    func testAnExactNameIsNeverReadAsATag() {
        let found = TranscriptFile.sidecarSetsByAudioPath(in: [
            file("show/ep1.mp3"), file("show/ep1.en.mp3"), file("show/ep1.en.vtt"),
        ])

        XCTAssertEqual(found["show/ep1.en.mp3"], ["show/ep1.en.vtt"])
        XCTAssertNil(found["show/ep1.mp3"])
    }

    func testTheEpisodesLanguageComesFirstThenTheAppsThenUntagged() {
        let paths = ["s/ep1.vtt", "s/ep1.en.vtt", "s/ep1.zh.vtt", "s/ep1.fr.vtt"]

        XCTAssertEqual(TranscriptFile.preferred(paths, episodeLanguage: "zh-CN", appLanguages: ["en-US"]).first, "s/ep1.zh.vtt")
        XCTAssertEqual(TranscriptFile.preferred(paths, episodeLanguage: nil, appLanguages: ["fr-FR", "en"]).first, "s/ep1.fr.vtt")
        XCTAssertEqual(TranscriptFile.preferred(paths, episodeLanguage: "ja", appLanguages: ["de"]).first, "s/ep1.vtt")
    }

    func testUploadWritesTheLanguagesOwnFile() {
        XCTAssertEqual(TranscriptFile.sidecarPath(forAudioPath: "s/ep1.mp3", extension: "vtt", language: "zh"), "s/ep1.zh.vtt")
        XCTAssertEqual(TranscriptFile.sidecarPath(forAudioPath: "s/ep1.mp3", extension: "vtt"), "s/ep1.vtt")
    }
}
