import Foundation
import GRDB

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

    /// Long enough for a sentence of context per fact, short enough that a profile of
    /// several paragraphs doesn't crowd out the facts after it.
    private static let maxDetailCharacters = 220
    private static let maxPromptCharacters = 1400

    var describedForPrompt: String {
        let terms = details
            .filter { !$0.isEmpty }
            .map { $0.count > Self.maxDetailCharacters ? $0.prefix(Self.maxDetailCharacters) + "…" : $0[...] }
        let described = ([name[...]] + terms).joined(separator: " · ")
        guard described.count > Self.maxPromptCharacters else { return described }
        return String(described.prefix(Self.maxPromptCharacters)) + "…"
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

    /// The same facts as a search box wants them: the connectives that make a prompt read
    /// as English are noise in a query, and a paragraph of notes buries the words that
    /// actually narrow it.
    var searchQuery: String {
        let connectives = ["speaker ", "from ", "by ", "host of "]
        let terms = details
            .filter { !$0.isEmpty && $0.count <= 40 }
            .map { term in
                connectives.first { term.hasPrefix($0) }
                    .map { String(term.dropFirst($0.count)) } ?? term
            }
        return ([name] + terms).joined(separator: " ")
    }

    /// Google Images rather than a model naming a URL. A model asked for "a photo of this
    /// person" answers with a link that looks right and often isn't — and the wrong face
    /// on a real speaker is the one mistake here that matters. Search results are a page
    /// of candidates the listener judges, which is what that job actually needs.
    /// `noiga=1` is what keeps this in the browser. Google's site claims `/search` as a
    /// universal link for the Google app, and a universal link overrides the phone's
    /// default-browser setting — tapping Search left for that app instead. The same file
    /// declares `noiga=1` as an exclusion, so the address stops being a universal link
    /// and iOS hands it to the default browser, which is where a page of candidate
    /// photographs belongs.
    var imageSearchURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "tbm", value: "isch"),
            URLQueryItem(name: "noiga", value: "1"),
        ]
        return components?.url
    }
}

/// Asks an image model for a picture, on whichever key can draw one.
///
/// A collection or an episode about a subject has no photograph of its own, and there an
/// image model drawing something evocative is exactly right. A real person's face is the
/// exception, and the reason the row beside this offers a search instead.
struct ArtworkSuggester {
    struct NoImageKeyError: Error, LocalizedError {
        var errorDescription: String? {
            "Drawing a picture needs an OpenAI or xAI key — the other vendors here only do text. Add one in Settings ▸ AI Features."
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

    /// `/v1/images/generations`, which OpenAI and xAI both speak — the same shape as the
    /// chat endpoint they also share, so there's one request here rather than two clients.
    ///
    /// Every attempt lands in the key's history the way a chat call does, win or lose.
    /// A picture is the most expensive single thing this app can ask for, and a spend
    /// that doesn't show up beside the others is a spend nobody notices.
    func picture(prompt: String) async throws -> Data {
        let store = AiKeyStore(dbQueue: dbQueue)
        let queryStore = AiQueryStore(dbQueue: dbQueue)
        let keys = try store.all().filter { $0.vendor == .openAI || $0.vendor == .xai }
        guard !keys.isEmpty else { throw NoImageKeyError() }

        var lastError: Error?
        for key in keys {
            guard let secret = try? store.secret(forKeyID: key.id), !secret.isEmpty else { continue }
            let model = Self.imageModel(for: key.vendor)
            try? store.bumpRequestCount(id: key.id)
            do {
                let data = try await Self.generate(prompt: prompt, vendor: key.vendor, apiKey: secret)
                // The picture itself stays out of the row: it's already saved wherever
                // the listener kept it, and a second copy per attempt would make the
                // history the biggest thing in the database.
                try? queryStore.recordImage(
                    keyID: key.id, vendor: key.vendor, model: model, prompt: prompt,
                    note: "One \(Self.imageSize) picture, \(data.count.formatted(.byteCount(style: .file)))"
                )
                return data
            } catch {
                try? queryStore.recordImage(
                    keyID: key.id, vendor: key.vendor, model: model, prompt: prompt, error: error
                )
                lastError = error
            }
        }
        throw lastError ?? NoImageKeyError()
    }

    private static let imageSize = "1024x1024"

    static func imageModel(for vendor: AiVendor) -> String {
        vendor == .openAI ? "gpt-image-1" : "grok-2-image"
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
            "model": imageModel(for: vendor),
            "prompt": prompt,
            "n": 1,
        ]
        // xAI's endpoint takes no size and refuses the request outright if one is sent.
        // Neither vendor takes `response_format` on this model — gpt-image-1 rejects it
        // as an unknown parameter and always answers in base64 anyway.
        if vendor == .openAI {
            body["size"] = imageSize
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

    /// Fetches the link an image model answered with, and insists it really is a picture:
    /// an HTML error page arriving as "artwork" is the normal failure here, not an exotic
    /// one.
    private static func fetchImage(at url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
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
