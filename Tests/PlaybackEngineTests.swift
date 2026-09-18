import MediaPlayer
import UIKit
import XCTest
@testable import BringYourOwnPodcasts

final class PlaybackEngineTests: XCTestCase {
    /// MediaPlayer asks for the lock-screen picture on a queue of its own. When the
    /// request handler was written inside `PlaybackEngine` it inherited the main actor,
    /// and the executor check killed the app (`EXC_BREAKPOINT`) as soon as an episode with
    /// artwork started playing. Asking for it off the main thread is the whole test.
    func testLockScreenArtworkCanBeAskedForOffTheMainThread() async {
        let size = CGSize(width: 120, height: 90)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }

        let artwork = PlaybackEngine.nowPlayingArtwork(image)
        let delivered = await Task.detached { artwork.image(at: size) }.value

        XCTAssertNotNil(delivered)
        XCTAssertEqual(delivered?.size, size)
    }
}
