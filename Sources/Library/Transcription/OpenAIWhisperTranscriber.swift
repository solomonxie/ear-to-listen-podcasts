import Foundation

/// Transcribes one window of audio via OpenAI's Whisper endpoint. Whisper is
/// OpenAI-specific — unlike chat completion (`AiRouter`), there's no other configured
/// vendor to fall back to, so it takes the first OpenAI key in Settings ▸ AI Features.
struct OpenAIWhisperTranscriber: SpeechTranscribing {
    let kind: TranscriptionEngineKind = .openAIWhisper

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let model = "whisper-1"
    private static let maxFileSizeBytes = 25 * 1_000_000

    static var hasKey: Bool {
        let store = AiKeyStore(dbQueue: DatabaseManager.shared.dbQueue)
        guard let key = try? store.all().first(where: { $0.vendor == .openAI }) else { return false }
        return (try? store.secret(forKeyID: key.id)).map { !$0.isEmpty } ?? false
    }

    /// No `onPartial`: the endpoint answers once, with the whole window.
    func transcribe(
        audioURL: URL,
        startOffset: Double,
        context: TranscriptionContext,
        onPartial: @escaping @Sendable (TranscriptDraft) -> Void
    ) async throws -> [TranscriptSegment] {
        let store = AiKeyStore(dbQueue: DatabaseManager.shared.dbQueue)
        guard
            let openAIKey = try? store.all().first(where: { $0.vendor == .openAI }),
            let apiKey = try? store.secret(forKeyID: openAIKey.id),
            !apiKey.isEmpty
        else {
            throw TranscriptionError.missingAPIKey
        }

        let fileData = try Data(contentsOf: audioURL)
        guard fileData.count <= Self.maxFileSizeBytes else { throw TranscriptionError.fileTooLarge }

        var fields = ["model": Self.model, "response_format": "verbose_json"]
        // Whisper guesses the language per request otherwise, and gets it wrong often
        // enough on short or noisy windows that one episode comes back in two languages.
        if let language = context.localeIdentifier?.split(separator: "-").first.map(String.init) {
            fields["language"] = language
        }
        // Whisper takes prior text as a style/vocabulary hint — this is where the user's
        // own corrections come back in as context.
        if let prompt = context.prompt { fields["prompt"] = prompt }

        let boundary = UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            fileData: fileData, fileName: audioURL.lastPathComponent, fields: fields, boundary: boundary
        )
        try? store.bumpRequestCount(id: openAIKey.id)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            // OpenAI puts the actual reason in the body ("invalid_api_key", quota, an
            // unsupported file); swallowing it left every failure reading the same.
            throw TranscriptionError.serverRejected(Self.errorMessage(in: data, response: response))
        }

        struct TranscriptionResponse: Decodable {
            struct Segment: Decodable { var start: Double; var end: Double?; var text: String }
            var segments: [Segment]?
        }
        guard
            let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
            let segments = decoded.segments
        else {
            throw TranscriptionError.invalidResponse
        }
        return segments.map {
            TranscriptSegment(
                start: startOffset + $0.start,
                end: startOffset + ($0.end ?? $0.start),
                text: $0.text.trimmingCharacters(in: .whitespaces),
                engine: kind.rawValue
            )
        }
    }

    private static func errorMessage(in data: Data, response: URLResponse) -> String {
        struct ErrorResponse: Decodable {
            struct Payload: Decodable { var message: String? }
            var error: Payload?
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message {
            return "\(message) (HTTP \(status))"
        }
        return "HTTP \(status)"
    }

    private static func multipartBody(fileData: Data, fileName: String, fields: [String: String], boundary: String) -> Data {
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
