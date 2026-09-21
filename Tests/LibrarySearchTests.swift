import XCTest
@testable import EarToListen

final class LibrarySearchTests: XCTestCase {
    private func track(_ title: String, path: String = "show/ep.mp3") -> Track {
        Track(
            id: title + path, providerID: "p1", artistID: nil, albumID: nil, filePath: path,
            title: title, trackNumber: nil, durationMs: nil, updatedAt: Date()
        )
    }

    private func index(
        tracks: [Track] = [], albums: [Album] = [], speakers: [Artist] = [], notes: [Bookmark] = []
    ) -> LibrarySearch.Index {
        LibrarySearch.index(
            speakers: speakers, albums: albums, playlists: [], topics: [], tracks: tracks,
            notes: notes
        )
    }

    // MARK: Everything with words in it

    /// What the listener typed into the app is the most findable thing there is — and
    /// used to be the one thing search couldn't see.
    func testAnEpisodeIsFoundByItsOwnNotes() {
        var episode = track("Untitled")
        episode.notes = "the one about harbour ferries"

        XCTAssertEqual(LibrarySearch.runSync("ferries", in: index(tracks: [episode])).tracks.count, 1)
    }

    func testASpeakerIsFoundByTheirBio() {
        let speaker = Artist(id: "a1", name: "Jane Doe", bio: "sleep researcher")

        XCTAssertEqual(
            LibrarySearch.runSync("sleep", in: index(speakers: [speaker])).speakers.map(\.name),
            ["Jane Doe"]
        )
    }

    func testACollectionIsFoundByItsNotes() {
        var album = Album(id: "al1", artistID: nil, name: "Season 3")
        album.notes = "recorded in the harbour"

        XCTAssertEqual(
            LibrarySearch.runSync("harbour", in: index(albums: [album])).albums.map(\.name),
            ["Season 3"]
        )
    }

    func testANoteIsFoundByWhatWasTypedOnIt() {
        let bookmark = Bookmark(
            id: "b1", trackID: "t1", positionMs: 1000, note: "check this quote",
            tags: "to check", transcriptText: nil, createdAt: Date()
        )

        XCTAssertEqual(LibrarySearch.runSync("quote", in: index(notes: [bookmark])).notes.count, 1)
        XCTAssertEqual(LibrarySearch.runSync("to check", in: index(notes: [bookmark])).notes.count, 1)
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
