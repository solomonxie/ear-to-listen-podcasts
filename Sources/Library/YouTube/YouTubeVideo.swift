import Foundation

/// A YouTube video kept as an episode: no audio of ours, only the video's ID, what the
/// listener wrote about it, and links back to YouTube. No Data API — oEmbed for the
/// title and channel, the embedded player for everything else.
enum YouTubeVideo {
    /// The `providers` row every YouTube episode hangs off, so `(providerID, filePath)`
    /// — the key backups use — is `("youtube", <video ID>)` on every install.
    static let providerID = "youtube"
    static let providerType = "youtube"

    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    /// The video ID in a link, or a bare ID. `youtu.be/…`, `watch?v=…`, `/shorts/…`,
    /// `/live/…`, `/embed/…`, on any youtube.com host.
    static func id(from link: String) -> String? {
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

    /// Opens the YouTube app at that moment when it's installed, Safari otherwise.
    static func watchURL(id: String, at seconds: TimeInterval = 0) -> URL {
        let t = max(Int(seconds), 0)
        return URL(string: "https://youtu.be/\(id)" + (t > 0 ? "?t=\(t)" : ""))!
    }

    static func thumbnailURLs(id: String) -> [URL] {
        ["maxresdefault", "hqdefault"].map { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg")! }
    }

    struct Info: Sendable {
        var title: String
        var channel: String?
    }

    /// Title and channel name from oEmbed — public, keyless, and a single request.
    static func info(id: String) async throws -> Info {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        struct OEmbed: Decodable { var title: String; var author_name: String? }
        let decoded = try JSONDecoder().decode(OEmbed.self, from: data)
        return Info(title: decoded.title, channel: decoded.author_name)
    }

    /// The largest thumbnail the video has — `maxresdefault` is missing on older uploads,
    /// where YouTube answers with a 120px grey placeholder rather than an error.
    static func thumbnail(id: String) async -> Data? {
        for url in thumbnailURLs(id: id) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count > 5_000 else { continue }
            return data
        }
        return nil
    }
}

extension Track {
    var youTubeID: String? { providerID == YouTubeVideo.providerID ? filePath : nil }
}
