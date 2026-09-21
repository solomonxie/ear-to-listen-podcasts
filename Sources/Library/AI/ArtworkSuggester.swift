import Foundation
import GRDB

/// Two ways to get a picture for something in the library out of an AI key, because they
/// answer different questions.
///
/// A real person has a face, and drawing one is worse than useless — it puts an invented
/// stranger on a real speaker. For them the right answer is a photograph that already
/// exists and is free to use, which a model is good at *naming* even though it can't
/// serve it: "the portrait on their Wikipedia page" is a fact about the world, and the
/// URL is checkable. A collection or an episode about a subject has no such photograph,
/// and there an image model drawing something evocative is exactly right.
enum ArtworkSource: String, CaseIterable, Identifiable, Sendable {
    /// An image model draws one from the prompt.
    case generated
    /// A chat model names a public image that already exists; the app fetches it.
    case publicPhoto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generated: return "Draw one"
        case .publicPhoto: return "Find a real photo"
        }
    }

    var detail: String {
        switch self {
        case .generated:
            return "An image model draws a picture from the description. Costs a few cents on your own key. Never use it for a real person's face."
        case .publicPhoto:
            return "A model names a public photo that already exists — a Wikipedia portrait, say — and the app fetches it. Costs what one short question costs. Check the credit before you keep it."
        }
    }
}

/// What the library already knows about the thing needing a picture, turned into the
/// description a model is handed. Metadata rather than a blank box: the listener has
/// already told the app who this is, and typing it again is the app's failure, not theirs.
struct ArtworkSubject: Sendable {
    enum Kind: String, Sendable {
        case episode, album, speaker
    }

    var kind: Kind
    var name: String
    /// Speaker, collection, year, topics, notes — whatever there is, in the order that
    /// identifies the subject fastest.
    var details: [String]

    var describedForPrompt: String {
        ([name] + details.filter { !$0.isEmpty }).joined(separator: " · ")
    }

    /// The prompt the sheet opens with. Editable — the listener knows things the tags
    /// don't.
    var defaultPrompt: String {
        switch kind {
        case .speaker:
            return "A portrait photograph of \(describedForPrompt)"
        case .album:
            return "Cover art for a podcast series: \(describedForPrompt). Bold, simple, readable at thumbnail size, no text."
        case .episode:
            return "Cover art for a podcast episode: \(describedForPrompt). Bold, simple, readable at thumbnail size, no text."
        }
    }
}

struct ArtworkSuggester {
    /// A picture and where it came from. The credit matters for the found kind: a photo
    /// with no idea who took it is a photo nobody can decide about.
    struct Found: Sendable {
        var data: Data
        var sourceURL: URL?
        var credit: String?
    }

    struct NoImageKeyError: Error, LocalizedError {
        var errorDescription: String? {
            "Drawing a picture needs an OpenAI or xAI key — the other vendors here only do text. Add one in Settings ▸ AI Features."
        }
    }

    struct NoPhotoFoundError: Error, LocalizedError {
        var errorDescription: String? {
            "No public photo came back for that. Try naming them more exactly, or draw one instead."
        }
    }

    struct UnusableImageError: Error, LocalizedError {
        var errorDescription: String? {
            "What came back wasn't a picture the app could read. Try again."
        }
    }

    /// Big enough to be worth keeping, small enough that a mistake costs a second.
    private static let maximumBytes = 12_000_000

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    func picture(for source: ArtworkSource, prompt: String) async throws -> Found {
        switch source {
        case .generated: return try await drawn(prompt: prompt)
        case .publicPhoto: return try await found(subject: prompt)
        }
    }

    // MARK: Drawing one

    /// `/v1/images/generations`, which OpenAI and xAI both speak — the same shape as the
    /// chat endpoint they also share, so there's one request here rather than two clients.
    private func drawn(prompt: String) async throws -> Found {
        let store = AiKeyStore(dbQueue: dbQueue)
        let keys = try store.all().filter { $0.vendor == .openAI || $0.vendor == .xai }
        guard !keys.isEmpty else { throw NoImageKeyError() }

        var lastError: Error?
        for key in keys {
            guard let secret = try? store.secret(forKeyID: key.id), !secret.isEmpty else { continue }
            do {
                return Found(data: try await Self.generate(prompt: prompt, vendor: key.vendor, apiKey: secret))
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NoImageKeyError()
    }

    private static func generate(prompt: String, vendor: AiVendor, apiKey: String) async throws -> Data {
        let endpoint = vendor == .openAI
            ? URL(string: "https://api.openai.com/v1/images/generations")!
            : URL(string: "https://api.x.ai/v1/images/generations")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        var body: [String: Any] = [
            "model": vendor == .openAI ? "gpt-image-1" : "grok-2-image",
            "prompt": prompt,
            "n": 1,
        ]
        // xAI's endpoint takes neither, and refuses the request outright if they're sent.
        if vendor == .openAI {
            body["size"] = "1024x1024"
            body["response_format"] = "b64_json"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AiClientError(
                code: (response as? HTTPURLResponse)?.statusCode == 401 ? .invalidKey : .unknown,
                message: Self.errorMessage(in: data)
                    ?? "\(vendor.displayName) refused the image request."
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else {
            throw UnusableImageError()
        }
        if let base64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: base64) {
            return decoded
        }
        // Some models hand back a link to the picture instead of the picture.
        guard let link = (first["url"] as? String).flatMap(URL.init(string:)) else {
            throw UnusableImageError()
        }
        return try await fetchImage(at: link)
    }

    // MARK: Finding one that exists

    private struct PhotoAnswer: Decodable {
        var url: String?
        var credit: String?
    }

    private func found(subject: String) async throws -> Found {
        let prompt = """
        Name one publicly available image for: \(subject)

        Rules:
        - It must be an image that already exists on the public internet and is free to \
        reuse — Wikipedia and Wikimedia Commons first, then an official page.
        - Give the direct file URL, the one ending in .jpg/.jpeg/.png/.webp \
        (on Wikimedia that is an `upload.wikimedia.org/...` link, not the article page).
        - If you are not confident the image exists at that exact URL, return null. A \
        wrong picture of a real person is worse than none.

        Strict JSON only, no other text:
        {"url": string|null, "credit": string|null}
        """

        let answer = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue
        )
        guard let json = EpisodeMetadataSuggester.jsonObject(in: answer),
              let decoded = try? JSONDecoder().decode(PhotoAnswer.self, from: Data(json.utf8)),
              let link = decoded.url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let url = URL(string: link), url.scheme == "https" else {
            throw NoPhotoFoundError()
        }
        return Found(
            data: try await Self.fetchImage(at: url), sourceURL: url,
            credit: decoded.credit?.nilIfEmpty
        )
    }

    /// Fetches a URL a model named, and insists it really is a picture. A model naming a
    /// link is a claim, not a fact — an HTML page or a 404 arriving as "artwork" is the
    /// normal failure here, not an exotic one.
    private static func fetchImage(at url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // Wikimedia refuses requests without one.
        request.setValue("EarToListen/1.0 (podcast player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.mimeType ?? "").hasPrefix("image/"), data.count < maximumBytes else {
            throw UnusableImageError()
        }
        return data
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
