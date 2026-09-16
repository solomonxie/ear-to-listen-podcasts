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
        case .system: return "System"
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

    @Published var language: AppLanguage {
        didSet { persist() }
    }

    /// `autoupdatingCurrent` for `.system`, so it tracks the device if that changes.
    var locale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.storageKey) ?? "") ?? .system
    }

    private func persist() {
        UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        if let identifier = language.localeIdentifier {
            UserDefaults.standard.set([identifier], forKey: Self.appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        }
    }
}
