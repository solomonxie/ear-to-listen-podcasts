import XCTest
@testable import EarToListen

/// The episodes in someone's bucket are the only thing in it this app can't rebuild. A
/// transcript can be re-run and a library restored from a snapshot; an overwritten MP3 is
/// gone. These lock the rule down at the boundary every write goes through, so it holds
/// for call sites that don't exist yet.
final class CloudWriteTests: XCTestCase {
    func testWritingToAnAudioKeyIsRefused() {
        for path in ["show/ep-01.mp3", "ep.m4a", "a/b/c.flac", "loud.WAV", "x.aiff"] {
            XCTAssertThrowsError(try CloudWrite.checked(path), "should refuse \(path)") { error in
                XCTAssertTrue(error is CloudWrite.WouldOverwriteAudioError)
            }
        }
    }

    func testSidecarsAndBackupsArePermitted() throws {
        for path in [
            "show/ep-01.vtt", "show/ep-01.lrc", "show/ep-01.zh-CN.vtt", "show/ep-01.jpg",
            "ear-to-listen-podcasts/2026-09.zip",
        ] {
            XCTAssertEqual(try CloudWrite.checked(path), path)
        }
    }

    func testAnEmptyPathIsRefused() {
        XCTAssertThrowsError(try CloudWrite.checked("")) { XCTAssertTrue($0 is CloudWrite.EmptyPathError) }
        XCTAssertThrowsError(try CloudWrite.checked("   ")) { XCTAssertTrue($0 is CloudWrite.EmptyPathError) }
    }

    /// The mirror image: an episode upload has to *be* audio, since the never-overwrite
    /// promise is kept by `uploadEpisode` checking the key is free — not by refusing audio.
    func testAnEpisodeUploadMustBeAudio() throws {
        for path in ["show/ep-01.mp3", "ep.m4a", "loud.WAV"] {
            XCTAssertEqual(try CloudWrite.checkedEpisode(path), path)
        }
        for path in ["show/ep-01.vtt", "cover.jpg", "notes.txt"] {
            XCTAssertThrowsError(try CloudWrite.checkedEpisode(path), "should refuse \(path)") { error in
                XCTAssertTrue(error is CloudWrite.NotAnEpisodeError)
            }
        }
        XCTAssertThrowsError(try CloudWrite.checkedEpisode(" ")) { XCTAssertTrue($0 is CloudWrite.EmptyPathError) }
    }

    func testACollidingNameIsRenamedRatherThanReplaced() {
        XCTAssertEqual(CloudWrite.availableName(for: "ep-01.mp3", avoiding: []), "ep-01.mp3")
        XCTAssertEqual(CloudWrite.availableName(for: "ep-01.mp3", avoiding: ["ep-01.mp3"]), "ep-01 2.mp3")
        XCTAssertEqual(
            CloudWrite.availableName(for: "ep-01.mp3", avoiding: ["ep-01.mp3", "ep-01 2.mp3"]),
            "ep-01 3.mp3"
        )
        XCTAssertEqual(CloudWrite.availableName(for: "clip", avoiding: ["clip"]), "clip 2")
    }

    /// The check is on the extension, not the folder — a sidecar is *supposed* to sit in
    /// the same directory as the episode it belongs to.
    func testASidecarBesideItsEpisodeIsFine() throws {
        XCTAssertEqual(
            try CloudWrite.checked("renwuzhi/2026/ep-01.vtt"), "renwuzhi/2026/ep-01.vtt"
        )
    }
}

final class TranscriptSidecarPathTests: XCTestCase {
    func testASidecarKeepsTheFolderAndBasenameAndSwapsTheExtension() {
        XCTAssertEqual(
            TranscriptFile.sidecarPath(forAudioPath: "podcast/ep1.mp3", extension: "vtt"),
            "podcast/ep1.vtt"
        )
    }

    /// The old version returned the audio path itself here — the one string this must
    /// never hand to a writer. Nothing is the right answer instead.
    func testAPathWithNothingLeftHasNoSidecarNameAtAll() {
        XCTAssertNil(TranscriptFile.sidecarPath(forAudioPath: "", extension: "vtt"))
    }

    /// Belt and braces: whatever a sidecar path comes out as, it must survive the write
    /// guard. This is the pairing that actually protects the audio.
    func testEverySidecarPathPassesTheWriteGuard() throws {
        for audio in ["a.mp3", "show/ep-01.m4a", "deep/nest/ing/track.flac"] {
            for ext in [TranscriptFile.canonicalExtension, TranscriptFile.companionExtension] {
                let path = try XCTUnwrap(TranscriptFile.sidecarPath(forAudioPath: audio, extension: ext))
                XCTAssertNoThrow(try CloudWrite.checked(path))
            }
        }
    }
}
