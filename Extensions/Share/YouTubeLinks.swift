import Foundation

/// Reading the video ID out of a YouTube link — shared by the app and its share extension,
/// so the extension only says "Added" for a link the app will be able to add.
enum YouTubeLinks {
    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    /// The video ID in a link, or a bare ID. `youtu.be/…`, `watch?v=…`, `/shorts/…`,
    /// `/live/…`, `/embed/…`, on any youtube.com host.
    static func videoID(in link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidID(text) { return text }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" {
            candidate = parts.first
        } else if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
                candidate = v
            } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
                candidate = parts[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        return candidate.flatMap { isValidID($0) ? $0 : nil }
    }
}
