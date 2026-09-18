import SwiftUI
import XCTest
@testable import EarToListen

/// The tap-anywhere dismissal lives on the window, so the thing that can silently fail is
/// the attaching: a recogniser added to a window that wasn't there yet does nothing, and
/// the keyboard stays up with no sign of why.
@MainActor
final class KeyboardDismissalTests: XCTestCase {
    func testAttachesToTheWindowAndEndsEditing() {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = UIHostingController(
            rootView: Text("page").dismissesKeyboardOnBackgroundTap()
        )
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        window.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())

        let taps = (window.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let coordinator = taps.compactMap { $0.delegate as? KeyboardDismissTap.Coordinator }.first
        XCTAssertNotNil(coordinator, "no dismissal recogniser on the window")
        // Buttons, links and scrolling must still see the touch.
        XCTAssertEqual(taps.first { $0.delegate === coordinator }?.cancelsTouchesInView, false)

        coordinator?.dismissKeyboard()
        XCTAssertFalse(field.isFirstResponder)
    }
}
