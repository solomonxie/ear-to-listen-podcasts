import XCTest

/// The 60-second path from the App Review notes, paced for a screen recording:
/// `scripts/review-recording.sh`.
final class ReviewWalkthroughUITests: XCTestCase {
    func testReviewPath() throws {
        let app = XCUIApplication()
        app.launch()
        pause(2)

        app.buttons["Try the sample library"].firstMatch.tapWhenReady()
        pause(3)

        let search = app.searchFields.firstMatch
        search.tapWhenReady()
        for character in "local church" { search.typeText(String(character)); usleep(120_000) }
        pause(2)

        let header = app.staticTexts["In transcripts"]
        for _ in 0..<6 where !header.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        pause(1)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: header.frame.midX, dy: header.frame.maxY + 40)).tap()
        pause(4)

        app.buttons["Transcript"].firstMatch.tapWhenReady()
        pause(4)

        let line = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'church'")).firstMatch
        line.press(forDuration: 1.0)
        pause(1)
        app.buttons["Edit"].firstMatch.tapWhenReady()
        pause(1)
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        field.typeText(" (corrected)")
        pause(2)
        app.buttons.matching(NSPredicate(format: "label IN {'Selected', 'checkmark.circle.fill', 'Save', 'Done'}")).firstMatch.tapWhenReady()
        pause(3)
    }

    private func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }
}

private extension XCUIElement {
    func tapWhenReady(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "missing: \(self)")
        tap()
    }
}
