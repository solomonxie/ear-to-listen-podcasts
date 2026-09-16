import Foundation

/// Which recognizer turns audio into text. Deliberately two, no more: one that costs
/// nothing and never leaves the phone, one that's more accurate but needs a key and a
/// round trip.
enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable {
    /// Apple's `Speech` framework, forced on-device. Ships with iOS — adds nothing to the
    /// app's download size, which is what rules out bundling a Whisper build ourselves.
    case onDevice
    case openAIWhisper

    var displayName: String {
        switch self {
        case .onDevice: return "On-device"
        case .openAIWhisper: return "OpenAI Whisper"
        }
    }

    var detail: String {
        switch self {
        case .onDevice: return "Apple's built-in recognizer. Free, offline, nothing added to the app's size."
        case .openAIWhisper: return "More accurate, needs an OpenAI key and sends audio to OpenAI."
        }
    }

    /// Longest stretch of audio handed over in one request. On-device recognition degrades
    /// badly on long files; Whisper's cap is the 25MB upload limit, not time.
    var windowSeconds: Double {
        switch self {
        case .onDevice: return 60
        case .openAIWhisper: return 600
        }
    }
}

/// Vocabulary hints derived from the user's own corrections, handed to the recognizer so
/// the names and terms they already fixed once stop coming back wrong.
struct TranscriptionContext: Sendable {
    var phrases: [String] = []

    var isEmpty: Bool { phrases.isEmpty }

    /// Whisper takes free text (a "previous transcript" style prompt), capped well under
    /// its ~224-token limit.
    var prompt: String? {
        guard !isEmpty else { return nil }
        return String(phrases.joined(separator: ", ").prefix(800))
    }

    /// Words the user typed in that weren't in the machine's version — the corrections
    /// themselves, rather than whole lines, which would just be noise.
    static func from(edits: [TranscriptEdit], limit: Int = 40) -> TranscriptionContext {
        var seen = Set<String>()
        var phrases: [String] = []
        for edit in edits {
            let before = Set(Self.words(in: edit.originalText).map { $0.lowercased() })
            for word in Self.words(in: edit.editedText) where !before.contains(word.lowercased()) {
                let key = word.lowercased()
                guard key.count > 1, !seen.contains(key) else { continue }
                seen.insert(key)
                phrases.append(word)
                if phrases.count >= limit { return TranscriptionContext(phrases: phrases) }
            }
        }
        return TranscriptionContext(phrases: phrases)
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}

enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case fileTooLarge
    case requestFailed
    case invalidResponse
    case onDeviceUnavailable
    case notAuthorized
    case sliceFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI key in Settings ▸ AI Features, or switch the transcript to On-device."
        case .fileTooLarge:
            return "This stretch of audio is over OpenAI's 25MB limit."
        case .requestFailed:
            return "Transcription request failed."
        case .invalidResponse:
            return "Transcription returned an unexpected response."
        case .onDeviceUnavailable:
            return "On-device speech recognition isn't available for this language on this device."
        case .notAuthorized:
            return "Allow Speech Recognition in iOS Settings to transcribe on-device."
        case .sliceFailed:
            return "Couldn't read that part of the audio file."
        }
    }
}

/// Transcribes one already-local window of audio. `startOffset` is where that window sits
/// in the full episode, so returned segments carry episode-relative timestamps.
protocol SpeechTranscribing: Sendable {
    var kind: TranscriptionEngineKind { get }
    func transcribe(audioURL: URL, startOffset: Double, context: TranscriptionContext) async throws -> [TranscriptSegment]
}

extension TranscriptionEngineKind {
    var transcriber: any SpeechTranscribing {
        switch self {
        case .onDevice: return AppleSpeechTranscriber()
        case .openAIWhisper: return OpenAIWhisperTranscriber()
        }
    }
}
