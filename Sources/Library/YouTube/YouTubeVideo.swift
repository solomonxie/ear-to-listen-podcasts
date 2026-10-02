import Foundation

/// A YouTube video kept as an episode: the video's ID, what the listener wrote about it,
/// and links back to YouTube. Played as the embedded video unless the listener's storage
/// holds an audio file named with its ID (`Track.youTubeVideoID`). No Data API — oEmbed
/// for the title and channel, the embedded player for the rest.
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

extension YouTubeVideo {
    /// The video a file in a bucket belongs to: its name starts with the ID, then a
    /// hyphen or the extension — `dQw4w9WgXcQ-never-gonna-give-you-up.mp3`,
    /// `dQw4w9WgXcQ.zh-Hans.vtt`. Whatever follows the ID can be renamed freely.
    static func id(inFileName path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.count > 12 else { return nil }
        let id = String(name.prefix(11))
        let next = name[name.index(name.startIndex, offsetBy: 11)]
        guard next == "-" || next == ".", isValidID(id) else { return nil }
        return id
    }

    /// A name made safe for a path: lowercase, spaces and punctuation turned to single
    /// hyphens, letters of any script kept. Empty when nothing's left.
    static func slug(_ name: String, maxLength: Int = 60) -> String {
        var out = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        return String(out.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

extension Track {
    var youTubeID: String? { youTubeVideoID }
    /// A YouTube episode with no audio file of its own — played as the embedded video.
    var isVideoOnly: Bool { providerID == YouTubeVideo.providerID }
}
