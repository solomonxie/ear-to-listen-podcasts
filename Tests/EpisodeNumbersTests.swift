import XCTest
@testable import EarToListen

/// The order a series is listened to in, and the numbers written into the library to keep
/// it. Both are easy to get subtly wrong — `ep-10` before `ep-9`, or a fill that lands on
/// a number someone typed by hand — so the edges are what's tested here.
final class EpisodeNumbersTests: XCTestCase {
    private func track(_ id: String, path: String, number: Int? = nil, album: String? = "a1") -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: album, filePath: path,
            title: id, trackNumber: number, durationMs: nil, updatedAt: Date()
        )
    }

    func testNumberedEpisodesComeFirstAndInNumberOrder() {
        let ordered = EpisodeNumbers.ordered([
            track("c", path: "show/zeta.mp3"),
            track("b", path: "show/talk.mp3", number: 10),
            track("a", path: "show/intro.mp3", number: 2),
        ])

        XCTAssertEqual(ordered.map(\.id), ["a", "b", "c"])
    }

    func testFilenamesSortTheWayAPersonReadsThem() {
        let ordered = EpisodeNumbers.ordered([
            track("ten", path: "show/ep-10.mp3"),
            track("nine", path: "show/ep-9.mp3"),
            track("one", path: "show/ep-1.mp3"),
        ])

        XCTAssertEqual(ordered.map(\.id), ["one", "nine", "ten"])
    }

    func testFilenamesOwnNumbersAreTakenWhenTheyAllAgree() {
        let assigned = EpisodeNumbers.assigned([
            track("a", path: "show/ep-003.mp3"),
            track("b", path: "show/ep-007.mp3"),
        ])

        XCTAssertEqual(assigned, ["a": 3, "b": 7])
    }

    /// A date in the name is two digit runs and no episode marker: counting in filename
    /// order is the only honest answer.
    func testAmbiguousFilenamesAreCountedInOrderInstead() {
        let assigned = EpisodeNumbers.assigned([
            track("b", path: "show/2024-05-03 talk.mp3"),
            track("a", path: "show/2024-01-09 talk.mp3"),
        ])

        XCTAssertEqual(assigned, ["a": 1, "b": 2])
    }

    func testOneAmbiguousNameSendsTheWholeAlbumBackToCounting() {
        let assigned = EpisodeNumbers.assigned([
            track("a", path: "show/ep-003.mp3"),
            track("b", path: "show/finale.mp3"),
        ])

        XCTAssertEqual(assigned, ["a": 1, "b": 2])
    }

    func testNumbersAlreadyInTheLibraryAreNeverReusedOrOverwritten() {
        let assigned = EpisodeNumbers.assigned([
            track("typed", path: "show/finale.mp3", number: 3),
            track("a", path: "show/ep-003.mp3"),
            track("b", path: "show/ep-004.mp3"),
        ])

        XCTAssertNil(assigned["typed"])
        // 3 is spoken for, so the filenames no longer agree and the rest are counted on
        // from the highest number in use.
        XCTAssertEqual(assigned, ["a": 4, "b": 5])
    }

    /// It runs after every sync, so its own output has to be a fixed point.
    func testASecondPassFillsNothing() {
        var tracks = [
            track("a", path: "show/ep-001.mp3"),
            track("b", path: "show/ep-002.mp3"),
        ]
        let first = EpisodeNumbers.assigned(tracks)
        for index in tracks.indices { tracks[index].trackNumber = first[tracks[index].id] }

        XCTAssertTrue(EpisodeNumbers.assigned(tracks).isEmpty)
    }

    func testEpisodeMarkersWinOverOtherDigitsInTheName() {
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "s2/2024 Episode 12.mp3"), 12)
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "第008讲.m4a"), 8)
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "show/042.mp3"), 42)
        XCTAssertNil(EpisodeNumbers.number(inFileName: "show/2024-05-03 talk.mp3"))
        XCTAssertNil(EpisodeNumbers.number(inFileName: "show/finale.mp3"))
    }

    /// Real names from a library that came out numbered by the part, not the folder.
    func testLeadingSequenceWinsOverAPartNumber() {
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "013_Jesus Appears Before Pilate, Part 1.m4a"), 13)
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "001_Christian Ethics, Pt. 4 Submission.m4a"), 1)
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "0013 - talk.mp3"), 13)
        XCTAssertEqual(EpisodeNumbers.number(inFileName: "2024 Episode 12.mp3"), 12)
    }

    /// A number the app assigned is open to correction on the next pass; one typed by hand
    /// is not.
    func testAppAssignedNumbersAreRederivedFromFilenames() {
        let tracks = [
            track("a", path: "v9/013_Jesus Appears Before Pilate, Part 1.m4a", number: 1),
            track("b", path: "v9/001_The Lord's Greatest Prayer, Part 5.m4a", number: 5),
            track("c", path: "v9/003_The Lord's Greatest Prayer, Part 6.m4a", number: 6),
        ]
        let fresh = EpisodeNumbers.assigned(tracks) { _ in false }
        XCTAssertEqual(fresh, ["b": 1, "c": 3, "a": 13])

        let typed = EpisodeNumbers.assigned(tracks) { $0.id == "a" }
        XCTAssertNil(typed["a"])
        // 1 is typed, so the names no longer agree and the rest count on after it, in
        // filename order.
        XCTAssertEqual(typed, ["b": 2, "c": 3])
    }
}
