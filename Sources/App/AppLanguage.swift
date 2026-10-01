import Foundation

/// In-app language override. Defaults to following the device, which is what an iOS app
/// does without any of this — the picker exists because this app's users often read in a
/// different language than their phone is set to.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    /// Each option is written in its own language, so it's readable while the app is
    /// still showing the *other* one — the whole point of the picker.
    var displayName: String {
        switch self {
        // Named for what it does, not what it is: "System" on its own leaves people
        // guessing which system, and whose language.
        case .system: return "Same as device"
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// `nil` = follow the device. Matches the project's `knownRegions`.
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    /// Before anyone picks, the China storefront reads in Chinese and everywhere else
    /// follows the device. A pick — even "Same as device" — always wins.
    static func initial(stored: String?, isChina: Bool) -> AppLanguage {
        if let picked = stored.flatMap(AppLanguage.init(rawValue:)) { return picked }
        return isChina ? .chinese : .system
    }
}

/// Holds the choice and hands the root view a `Locale`. SwiftUI resolves every
/// `Text("…")` against `\.locale`, so switching swaps the visible language immediately
/// rather than after a relaunch; `AppleLanguages` is written too so anything resolved
/// straight off the bundle (and any future non-SwiftUI code) agrees on the next launch.
@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    private static let storageKey = "app.language"
    private static let appleLanguagesKey = "AppleLanguages"
    /// Set while `AppleLanguages` holds the storefront's default rather than a pick, so
    /// it can be taken back if the storefront changes.
    private static let storefrontDefaultKey = "app.language.storefrontDefault"

    @Published var language: AppLanguage {
        didSet { persist() }
    }

    /// `autoupdatingCurrent` for `.system`, so it tracks the device if that changes.
    var locale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.storageKey)
        // A language picked in iOS Settings ▸ Ear to Listen lands in this app's own
        // `AppleLanguages`; that's a choice too, and the storefront never overrides it.
        let pickedInIOS = !defaults.bool(forKey: Self.storefrontDefaultKey)
            && Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0)?[Self.appleLanguagesKey] } != nil
        language = AppLanguage.initial(stored: stored, isChina: AppStorefront.isChina && !pickedInIOS)
        guard stored == nil, !pickedInIOS else { return }
        // Unpicked: not saved as a choice. `Text` follows `locale` at once; strings read
        // straight off the bundle follow `AppleLanguages` from the next launch.
        if language == .chinese {
            defaults.set(["zh-Hans"], forKey: Self.appleLanguagesKey)
            defaults.set(true, forKey: Self.storefrontDefaultKey)
        } else if defaults.bool(forKey: Self.storefrontDefaultKey) {
            defaults.removeObject(forKey: Self.appleLanguagesKey)
            defaults.removeObject(forKey: Self.storefrontDefaultKey)
        }
    }

    private func persist() {
        UserDefaults.standard.removeObject(forKey: Self.storefrontDefaultKey)
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        if let identifier = language.localeIdentifier {
            UserDefaults.standard.set([identifier], forKey: Self.appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        }
    }
}
