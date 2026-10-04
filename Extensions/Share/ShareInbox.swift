import Foundation

/// Links shared into the app from another one, waiting for the app to open. The share
/// extension can't reach the library's database, so it leaves them here — in the App
/// Group both can read — and `YouTubeEpisodes.addShared` makes them into episodes.
enum ShareInbox {
    /// `AppGroupIdentifier` is written into both the app's and the extension's Info.plist
    /// from the same build setting, so the two resolve the same group.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    private static let key = "share.inbox"

    private static var defaults: UserDefaults? { appGroup.flatMap(UserDefaults.init(suiteName:)) }

    static func add(_ link: String) {
        guard let defaults else { return }
        defaults.set((defaults.stringArray(forKey: key) ?? []) + [link], forKey: key)
    }

    static func takeAll() -> [String] {
        guard let defaults, let links = defaults.stringArray(forKey: key), !links.isEmpty else { return [] }
        defaults.removeObject(forKey: key)
        return links
    }
}
