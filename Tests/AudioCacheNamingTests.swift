import XCTest
@testable import EarToListen

/// Downloads live in `Documents/Downloads` now, which is a folder the listener opens in
/// Files. That makes the filename part of the product — and makes collisions a real
/// hazard, because two buckets can both hold `ep-01.mp3` in one flat folder.
final class AudioCacheNamingTests: XCTestCase {
    private func name(_ providerID: String, _ filePath: String) -> String {
        AudioCache.fileName(providerID: providerID, filePath: filePath)
    }

    func testTheNameKeepsTheEpisodesOwnFilenameAndExtension() {
        let result = name("p1", "renwuzhi/2026/ep-01.mp3")

        XCTAssertTrue(result.hasPrefix("ep-01~"), "got \(result)")
        XCTAssertTrue(result.hasSuffix(".mp3"), "got \(result)")
    }

    /// The whole reason for the suffix. Same filename, different bucket — one must not
    /// serve the other's audio.
    func testTheSameFilenameInTwoProvidersGetsTwoNames() {
        XCTAssertNotEqual(name("p1", "show/ep-01.mp3"), name("p2", "show/ep-01.mp3"))
    }

    /// Same filename, different folder in the *same* bucket — also has to stay apart,
    /// since the folder is flattened away.
    func testTheSameFilenameInTwoFoldersGetsTwoNames() {
        XCTAssertNotEqual(name("p1", "2025/ep-01.mp3"), name("p1", "2026/ep-01.mp3"))
    }

    func testTheSameFileAlwaysGetsTheSameName() {
        XCTAssertEqual(name("p1", "show/ep-01.mp3"), name("p1", "show/ep-01.mp3"))
    }

    /// The extension is what tells AVFoundation the file is audio at all — an entry
    /// without one can play and still refuse to transcribe.
    func testTheExtensionIsPreservedAndLowercased() {
        XCTAssertTrue(name("p1", "show/EP-01.M4A").hasSuffix(".m4a"))
    }

    func testAFileWithNoExtensionStillGetsAUsableName() {
        let result = name("p1", "show/episode")

        XCTAssertTrue(result.hasPrefix("episode~"), "got \(result)")
        XCTAssertFalse(result.contains("/"))
    }

    /// Nothing in the name may look like a path component — it's written straight into a
    /// flat directory.
    func testAwkwardCharactersDontEscapeTheFolder() {
        for path in ["a/b/../ep.mp3", "weird:name.mp3", "~/ep.mp3"] {
            let result = name("p1", path)
            XCTAssertFalse(result.contains("/"), "got \(result)")
            XCTAssertFalse(result.hasPrefix("~"), "got \(result)")
        }
    }

    func testIsCachedMatchesTheNameOnDisk() {
        let keys: Set<String> = [name("p1", "show/ep-01.mp3")]

        XCTAssertTrue(AudioCache.shared.isCached(keys, providerID: "p1", filePath: "show/ep-01.mp3"))
        XCTAssertFalse(AudioCache.shared.isCached(keys, providerID: "p2", filePath: "show/ep-01.mp3"))
    }
}
