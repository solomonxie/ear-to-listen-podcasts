import Foundation
import StoreKit

/// Which App Store the app was installed from — the China storefront may only offer AI
/// vendors licensed there, so everything that lists or calls a vendor asks this first.
///
/// Release reads StoreKit's answer, cached from the last `refresh()`; before the first
/// one lands, the device region stands in. Debug builds act as the storefront picked at
/// install time (`make ios STOREFRONT=CHN`), or a launch argument's. Nothing on screen
/// changes it, in any build.
enum AppStorefront {
    static let chinaCode = "CHN"
    private static let lastKnownKey = "storefront.lastKnown"
    /// Debug only, as a launch argument: `-storefrontOverride CHN`.
    private static let overrideArgument = "-storefrontOverride"

    static var countryCode: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: overrideArgument), flag + 1 < arguments.count {
            return arguments[flag + 1]
        }
        if let installed = (Bundle.main.object(forInfoDictionaryKey: "EarStorefront") as? String)?.nilIfEmpty {
            return installed
        }
        #endif
        return UserDefaults.standard.string(forKey: lastKnownKey)
            ?? (Locale.current.region?.identifier == "CN" ? chinaCode : nil)
    }

    static var isChina: Bool { countryCode == chinaCode }

    static func refresh() async {
        guard let code = await Storefront.current?.countryCode else { return }
        UserDefaults.standard.set(code, forKey: lastKnownKey)
    }
}
