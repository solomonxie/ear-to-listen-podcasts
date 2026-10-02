import UIKit

/// Settings' "Keep screen on": the phone doesn't lock itself while the app is open — for
/// reading along with a transcript, or a video playing on the episode page.
enum ScreenAwake {
    static let key = "screen.keepOn"

    /// iOS only honours this while the app is in front, so it's set again on every return.
    @MainActor
    static func apply() {
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: key)
    }
}
