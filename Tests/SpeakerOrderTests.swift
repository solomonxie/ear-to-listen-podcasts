import XCTest
@testable import EarToListen

/// Home's Speakers shelf is scrolled sideways, so what it puts in the first two places is
/// nearly all of it.
final class SpeakerOrderTests: XCTestCase {
    private func speaker(_ id: String, _ name: String) -> Artist {
        Artist(id: id, name: name)
    }

    private func track(_ id: String, speaker: String?, playedAt: Date?) -> Track {
        Track(
            id: id, providerID: "p1", artistID: speaker, albumID: "al1",
            filePath: "show/\(id).mp3", title: id, trackNumber: nil, durationMs: nil,
            updatedAt: Date(), lastPlayedAt: playedAt
        )
    }

    private let now = Date()

    func testTheSpeakerHeardLastComesFirst() {
        let ordered = SpeakerOrder.byLastActivity(
            [speaker("a", "Aaron"), speaker("b", "Zoe")],
            tracks: [
                track("t1", speaker: "a", playedAt: now.addingTimeInterval(-3600)),
                track("t2", speaker: "b", playedAt: now),
            ]
        )

        XCTAssertEqual(ordered.map(\.id), ["b", "a"])
    }

    /// A speaker is as recent as their most recently played episode, not their oldest.
    func testTheirNewestPlayCounts() {
        let ordered = SpeakerOrder.byLastActivity(
            [speaker("a", "Aaron"), speaker("b", "Zoe")],
            tracks: [
                track("t1", speaker: "a", playedAt: now.addingTimeInterval(-86400)),
                track("t2", speaker: "a", playedAt: now),
                track("t3", speaker: "b", playedAt: now.addingTimeInterval(-3600)),
            ]
        )

        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }

    func testNeverPlayedSpeakersFollowInNameOrder() {
        let ordered = SpeakerOrder.byLastActivity(
            [speaker("z", "Zoe"), speaker("m", "Maria"), speaker("a", "Aaron")],
            tracks: [track("t1", speaker: "z", playedAt: now)]
        )

        XCTAssertEqual(ordered.map(\.id), ["z", "a", "m"])
    }

    /// Importing or re-tagging an episode isn't listening to it.
    func testSyncingAnEpisodeDoesNotMoveItsSpeaker() {
        let ordered = SpeakerOrder.byLastActivity(
            [speaker("a", "Aaron"), speaker("b", "Zoe")],
            tracks: [
                track("t1", speaker: "a", playedAt: now.addingTimeInterval(-86400)),
                track("t2", speaker: "b", playedAt: nil),
            ]
        )

        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }
}
