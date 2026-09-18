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

    /// How each one reads as a button: a phone for the one that runs on it, sparkles for
    /// the one that goes off to a vendor.
    var symbolName: String {
        switch self {
        case .onDevice: return "iphone"
        case .openAIWhisper: return "sparkles"
        }
    }

    var detail: String {
        switch self {
        case .onDevice: return "Apple's built-in recognizer. Free, offline, nothing added to the app's size."
        case .openAIWhisper: return "More accurate, needs an OpenAI key and sends audio to OpenAI."
        }
    }

    /// What a minute of audio costs, where anyone is charged for it. Nil means free —
    /// on-device recognition spends battery, which is not a number worth putting in front
    /// of someone. `whisper-1` is $0.006/minute; if the model changes, this does too.
    var pricePerMinuteUSD: Double? {
        switch self {
        case .onDevice: return nil
        case .openAIWhisper: return 0.006
        }
    }

    /// Longest stretch of audio handed over in one request. On-device recognition degrades
    /// badly on long files; Whisper's cap is the 25MB upload limit, not time.
    var windowSeconds: Double {
        switch self {
        // Short on purpose: a window is only saved once it finishes, so this is also how
        // much work a jump to elsewhere in the episode throws away.
        case .onDevice: return 30
        // Sized against Whisper's 25MB upload rather than its clock: a window now travels as
        // 16 kHz mono WAV (~32 kB/s), so five minutes is ~9.6MB with room to spare.
        case .openAIWhisper: return 300
        }
    }
}

/// Vocabulary hints derived from the user's own corrections, handed to the recognizer so
/// the names and terms they already fixed once stop coming back wrong.
struct TranscriptionContext: Sendable {
    var phrases: [String] = []
    /// What language the *audio* is in — which has nothing to do with what language the
    /// phone is in. A listener with an English phone and a Mandarin podcast was getting
    /// the en-US model, which recognises Mandarin as nonsense and never stops trying.
    var localeIdentifier: String?

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
    case serverRejected(String)
    case invalidResponse
    case onDeviceUnavailable(locale: String)
    case onDeviceModelMissing(locale: String)
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
        case .serverRejected(let detail):
            return "OpenAI refused the transcription: \(detail)"
        case .invalidResponse:
            return "Transcription returned an unexpected response."
        case .onDeviceUnavailable(let locale):
            return "On-device speech recognition (\(locale)) isn't available right now. It can take a moment after launch — try again."
        case .onDeviceModelMissing(let locale):
            return "This iPhone couldn't recognise \(locale) offline. Add that language under Settings ▸ General ▸ Keyboard ▸ Dictation Languages — iOS downloads the model over Wi-Fi, which can take a few minutes — then try again, or switch the transcript to OpenAI Whisper."
        case .notAuthorized:
            return "Allow Speech Recognition in iOS Settings to transcribe on-device."
        case .sliceFailed:
            return "Couldn't decode that part of the audio — the file may be a format iOS can't read."
        }
    }
}

/// Transcribes one already-local window of audio. `startOffset` is where that window sits
/// in the full episode, so returned segments carry episode-relative timestamps.
///
/// `onPartial` hands back the lines made out so far, as often as the engine has something
/// new. That's what makes text appear while a window is still being worked on rather than
/// a whole window at a time; an engine that can't stream simply never calls it.
protocol SpeechTranscribing: Sendable {
    var kind: TranscriptionEngineKind { get }
    func transcribe(
        audioURL: URL,
        startOffset: Double,
        context: TranscriptionContext,
        onPartial: @escaping @Sendable (TranscriptDraft) -> Void
    ) async throws -> [TranscriptSegment]
}

extension SpeechTranscribing {
    func transcribe(audioURL: URL, startOffset: Double, context: TranscriptionContext) async throws -> [TranscriptSegment] {
        try await transcribe(audioURL: audioURL, startOffset: startOffset, context: context, onPartial: { _ in })
    }
}

extension TranscriptionEngineKind {
    var transcriber: any SpeechTranscribing {
        switch self {
        case .onDevice: return AppleSpeechTranscriber()
        case .openAIWhisper: return OpenAIWhisperTranscriber()
        }
    }
}
