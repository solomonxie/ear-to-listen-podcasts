import CarPlay
import UIKit

/// The car's scene. The phone's window stays with SwiftUI's `WindowGroup`; this is the
/// only scene role declared in the manifest.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var car: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let car = CarPlayController(interface: interfaceController)
        car.start()
        self.car = car
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        car?.stop()
        car = nil
    }
}
