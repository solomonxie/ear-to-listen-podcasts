import XCTest
@testable import EarToListen

/// Sidecars sit flat beside the audio, so a shared basename is the only thing tying
/// `ep-01.vtt` to `ep-01.mp3`. These lock down that match — including the cases where
/// getting it wrong would hide a file the listener put there themselves.
final class RemoteFileGroupTests: XCTestCase {
    private func file(_ path: String) -> CloudFile {
        CloudFile(
            id: path, name: (path as NSString).lastPathComponent, path: path,
            sizeBytes: 1, mimeType: nil, modifiedAt: nil
        )
    }

    func testSidecarsFoldIntoTheEpisodeTheyShareABasenameWith() {
        let groups = RemoteFileGroup.group([
            file("show/ep-01.mp3"), file("show/ep-01.vtt"), file("show/ep-01.lrc"), file("show/ep-01.jpg"),
            file("show/ep-02.mp3"), file("show/ep-02.vtt"),
        ])

        XCTAssertEqual(groups.map { $0.file.name }, ["ep-01.mp3", "ep-02.mp3"])
        XCTAssertEqual(groups[0].sidecars.map(\.name), ["ep-01.vtt", "ep-01.lrc", "ep-01.jpg"])
        XCTAssertEqual(groups[1].sidecars.map(\.name), ["ep-02.vtt"])
    }

    /// The Plex/Jellyfin convention for a second language, and the reason matching walks
    /// off one extension at a time instead of comparing basenames outright.
    func testALanguageTaggedTranscriptStillFindsItsEpisode() {
        let groups = RemoteFileGroup.group([
            file("show/ep-01.mp3"), file("show/ep-01.vtt"), file("show/ep-01.zh-CN.vtt"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sidecars.map(\.name), ["ep-01.vtt", "ep-01.zh-CN.vtt"])
    }

    /// A bucket is the user's own. Anything that isn't claimed by an episode keeps its own
    /// row rather than disappearing into one.
    func testUnclaimedFilesStayVisibleAsTheirOwnRows() {
        let groups = RemoteFileGroup.group([
            file("show/ep-01.mp3"), file("show/ep-01.vtt"),
            file("show/cover.jpg"), file("show/notes.txt"),
        ])

        XCTAssertEqual(groups.map { $0.file.name }, ["ep-01.mp3", "cover.jpg", "notes.txt"])
        XCTAssertTrue(groups[1].sidecars.isEmpty)
        XCTAssertTrue(groups[2].sidecars.isEmpty)
    }

    /// Two episodes whose names differ only by extension are still two episodes — folding
    /// `ep-01.m4a` into `ep-01.mp3` would hide one of them.
    func testTwoAudioFilesSharingABasenameAreBothKept() {
        let groups = RemoteFileGroup.group([file("show/ep-01.mp3"), file("show/ep-01.m4a")])

        XCTAssertEqual(groups.map { $0.file.name }, ["ep-01.mp3", "ep-01.m4a"])
    }

    func testHasTranscriptOnlyCountsTranscriptSidecars() {
        let withText = RemoteFileGroup.group([file("show/ep-01.mp3"), file("show/ep-01.vtt")])
        let withArtOnly = RemoteFileGroup.group([file("show/ep-02.mp3"), file("show/ep-02.jpg")])

        XCTAssertTrue(withText[0].hasTranscript)
        XCTAssertFalse(withArtOnly[0].hasTranscript)
    }
}
