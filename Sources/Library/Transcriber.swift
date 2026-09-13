import Foundation

enum TranscriberError: LocalizedError {
    case missingAPIKey
    case fileTooLarge
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Set an OpenAI API key in Settings ▸ AI Features to transcribe episodes."
        case .fileTooLarge: "This episode is over OpenAI's 25MB transcription limit."
        case .requestFailed: "Transcription request failed."
        case .invalidResponse: "Transcription returned an unexpected response."
        }
    }
}

/// Live, on-demand transcription via OpenAI's Whisper endpoint. Only plain timestamped
/// segments come back — no speaker diarization. Runs against the actual audio (unlike
/// `ContentAnalyzer`, which only ever sees a file's path), so it's triggered per-track on
/// playback rather than during sync.
struct Transcriber {
    private let credentials = CredentialStore()

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let model = "whisper-1"
    private static let maxFileSizeBytes = 25 * 1_000_000

    func transcribe(track: Track, provider: CloudProvider) async throws -> [TranscriptSegment] {
        guard
            let apiKey = try? credentials.get(SettingsViewModel.openAIAPIKeyKey),
            !apiKey.isEmpty
        else {
            throw TranscriberError.missingAPIKey
        }

        let fileURL = try await localAudioURL(track: track, provider: provider)
        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count <= Self.maxFileSizeBytes else { throw TranscriberError.fileTooLarge }

        let boundary = UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            fields: ["model": Self.model, "response_format": "verbose_json"],
            boundary: boundary
        )

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            throw TranscriberError.requestFailed
        }

        struct TranscriptionResponse: Decodable {
            struct Segment: Decodable { var start: Double; var text: String }
            var segments: [Segment]?
        }
        guard
            let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
            let segments = decoded.segments
        else {
            throw TranscriberError.invalidResponse
        }
        return segments.map { TranscriptSegment(start: $0.start, text: $0.text.trimmingCharacters(in: .whitespaces)) }
    }

    /// Reuses the playback disk cache, so transcribing a track also warms it for playback.
    private func localAudioURL(track: Track, provider: CloudProvider) async throws -> URL {
        if let cached = await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) {
            return cached
        }
        let remote = try await provider.streamURL(forFileID: track.filePath)
        if remote.isFileURL { return remote }
        return try await AudioCache.shared.store(remoteURL: remote, providerID: track.providerID, filePath: track.filePath)
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
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
