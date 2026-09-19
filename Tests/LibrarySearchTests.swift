import XCTest
@testable import EarToListen

final class LibrarySearchTests: XCTestCase {
    private func track(_ title: String, path: String = "show/ep.mp3") -> Track {
        Track(
            id: title + path, providerID: "p1", artistID: nil, albumID: nil, filePath: path,
            title: title, trackNumber: nil, durationMs: nil, updatedAt: Date()
        )
    }

    private func index(tracks: [Track] = [], albums: [Album] = []) -> LibrarySearch.Index {
        LibrarySearch.index(
            speakers: [], albums: albums, playlists: [], topics: [], tracks: tracks
        )
    }

    func testMatchingIsCaseInsensitive() {
        let results = LibrarySearch.runSync("SLEEP", in: index(tracks: [track("Sleep Toolkit")]))

        XCTAssertEqual(results.tracks.map(\.title), ["Sleep Toolkit"])
    }

    /// The reason the path is indexed at all: a folder of files sharing one embedded title
    /// tag leaves the filename as the only thing that tells them apart.
    func testAnEpisodeIsFoundByItsPathAsWellAsItsTitle() {
        let tracks = [track("Untitled", path: "renwuzhi/2026/ep-07.mp3")]

        XCTAssertEqual(LibrarySearch.runSync("ep-07", in: index(tracks: tracks)).tracks.count, 1)
        XCTAssertEqual(LibrarySearch.runSync("renwuzhi", in: index(tracks: tracks)).tracks.count, 1)
    }

    /// A one-letter query matches nearly everything, and every row returned is a row
    /// SwiftUI has to build. The cap is what keeps typing responsive.
    func testEpisodeResultsAreCappedButTheRealCountIsKept() {
        let many = (0..<500).map { track("Episode \($0)", path: "show/ep-\($0).mp3") }

        let results = LibrarySearch.runSync("episode", in: index(tracks: many))

        XCTAssertEqual(results.tracks.count, LibrarySearch.episodeLimit)
        XCTAssertEqual(results.totalTrackMatches, 500, "the header needs the number it didn't show")
    }

    func testAnEmptyOrBlankQueryMatchesNothing() {
        let tracks = [track("Sleep Toolkit")]

        XCTAssertTrue(LibrarySearch.runSync("", in: index(tracks: tracks)).isEmpty)
        XCTAssertTrue(LibrarySearch.runSync("   ", in: index(tracks: tracks)).isEmpty)
    }

    func testNonLatinTextMatchesOnASubstring() {
        let tracks = [track("第 3 集 — 人物志", path: "renwuzhi/ep-03.mp3")]

        XCTAssertEqual(LibrarySearch.runSync("人物", in: index(tracks: tracks)).tracks.count, 1)
    }

    func testSearchingSpansEveryKindAtOnce() {
        let album = Album(id: "a1", artistID: nil, name: "Sleep Series")
        let results = LibrarySearch.runSync(
            "sleep", in: index(tracks: [track("Sleep Toolkit")], albums: [album])
        )

        XCTAssertEqual(results.albums.count, 1)
        XCTAssertEqual(results.tracks.count, 1)
        XCTAssertFalse(results.isEmpty)
    }
}
