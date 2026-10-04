import Foundation

/// The ids this build was signed with, read back from the bundle: the real values live
/// only in the gitignored `Config/Local.xcconfig`, never in source.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.example.eartolisten"

    /// `com.example` of `com.example.eartolisten` — what the app's earlier names shared.
    static let bundleIDPrefix = bundleID.split(separator: ".").dropLast().joined(separator: ".")

    static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
