import XCTest
@testable import EarToListen

/// The prompt asks for null on anything the model can't improve on, and a model that
/// doesn't know a person is *supposed* to return nulls. So the decoding has to treat a
/// missing field, an explicit null, and a blank string as the same answer — otherwise an
/// empty string lands as a suggestion and wipes a hand-written bio when it's accepted.
final class SpeakerProfileSuggestionTests: XCTestCase {
    private func decode(_ json: String) throws -> SpeakerProfileSuggester.Suggestion {
        try JSONDecoder().decode(SpeakerProfileSuggester.Suggestion.self, from: Data(json.utf8))
    }

    func testAFullAnswerDecodes() throws {
        let suggestion = try decode("""
        {"bio": "Neuroscientist and podcaster", "knownFor": "sleep, dopamine, focus",
         "background": "Professor at Stanford.", "profile": "Two paragraphs here."}
        """)

        XCTAssertEqual(suggestion.bio, "Neuroscientist and podcaster")
        XCTAssertEqual(suggestion.knownFor, "sleep, dopamine, focus")
        XCTAssertEqual(suggestion.background, "Professor at Stanford.")
        XCTAssertEqual(suggestion.profile, "Two paragraphs here.")
        XCTAssertFalse(suggestion.isEmpty)
    }

    /// The honest answer when the model can't place someone — it must survive decoding as
    /// "nothing to suggest" rather than as four blank fields to write.
    func testNullsAndBlanksBothMeanNoSuggestion() throws {
        let nulls = try decode("""
        {"bio": null, "knownFor": null, "background": null, "profile": null}
        """)
        let blanks = try decode("""
        {"bio": "", "knownFor": "   ", "background": "\\n", "profile": ""}
        """)

        XCTAssertTrue(nulls.isEmpty)
        XCTAssertTrue(blanks.isEmpty, "a blank string is not a suggestion")
    }

    func testMissingKeysAreToleratedRatherThanFailingTheWholePass() throws {
        let suggestion = try decode(#"{"knownFor": "history, biography"}"#)

        XCTAssertEqual(suggestion.knownFor, "history, biography")
        XCTAssertNil(suggestion.bio)
        XCTAssertNil(suggestion.background)
        XCTAssertFalse(suggestion.isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let suggestion = try decode(#"{"bio": "  Historian.  "}"#)

        XCTAssertEqual(suggestion.bio, "Historian.")
    }
}

final class AlbumProfileSuggestionTests: XCTestCase {
    private func decode(_ json: String) throws -> AlbumProfileSuggester.Suggestion {
        try JSONDecoder().decode(AlbumProfileSuggester.Suggestion.self, from: Data(json.utf8))
    }

    func testAFullAnswerDecodes() throws {
        let suggestion = try decode("""
        {"notes": "A biography series.", "profile": "Longer read.", "year": 2026}
        """)

        XCTAssertEqual(suggestion.notes, "A biography series.")
        XCTAssertEqual(suggestion.profile, "Longer read.")
        XCTAssertEqual(suggestion.year, 2026)
    }

    /// Models return a year as a string about as often as a number, and sometimes as a
    /// full date — same tolerance `AlbumMetadataSuggester` already has.
    func testAYearArrivesAsANumberAStringOrADate() throws {
        XCTAssertEqual(try decode(#"{"year": 2026}"#).year, 2026)
        XCTAssertEqual(try decode(#"{"year": "2026"}"#).year, 2026)
        XCTAssertEqual(try decode(#"{"year": "2026-03-01"}"#).year, 2026)
        XCTAssertNil(try decode(#"{"year": null}"#).year)
    }

    func testNothingUsableReadsAsEmpty() throws {
        XCTAssertTrue(try decode(#"{"notes": null, "profile": "", "year": null}"#).isEmpty)
    }
}

/// A link is the one part of a profile that can be checked against the outside world —
/// which is exactly why a fabricated one is worse than none: it reads as a citation.
final class SpeakerLinkTests: XCTestCase {
    private func decode(_ json: String) throws -> SpeakerProfileSuggester.Suggestion {
        try JSONDecoder().decode(SpeakerProfileSuggester.Suggestion.self, from: Data(json.utf8))
    }

    func testAPlainHttpsLinkIsKept() throws {
        let suggestion = try decode(#"{"link": "https://en.wikipedia.org/wiki/Stephen_Tong"}"#)

        XCTAssertEqual(suggestion.link, "https://en.wikipedia.org/wiki/Stephen_Tong")
    }

    func testAnythingThatIsntAnHttpAddressIsDropped() throws {
        for candidate in ["not a url", "wikipedia.org/wiki/X", "javascript:alert(1)", "file:///etc/passwd", ""] {
            let json = "{\"link\": \(String(data: try JSONEncoder().encode(candidate), encoding: .utf8)!)}"
            XCTAssertNil(try decode(json).link, "should have dropped \(candidate)")
        }
    }

    func testALinkAloneStillCountsAsASuggestion() throws {
        XCTAssertFalse(try decode(#"{"link": "https://example.org/a"}"#).isEmpty)
    }
}
