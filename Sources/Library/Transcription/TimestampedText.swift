import Foundation

/// Plain text with a timestamp on each line, the way video sites lay out a transcript.
/// Subtitle formats are passed through to `TranscriptFile`.
///
/// Usually a timestamp line, then the words, then the next timestamp —
/// sometimes with the timestamp and words on one line, sometimes with a spoken-out
/// duration ("1 minute, 5 seconds") between them for screen readers.
enum TimestampedText {
    static func parse(_ text: String) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("WEBVTT") { return TranscriptFile.parse(trimmed, extension: "vtt") }
        if trimmed.contains("-->") { return TranscriptFile.parse(trimmed, extension: "srt") }
        if trimmed.range(of: #"^\[\d+:\d{2}"#, options: .regularExpression) != nil {
            return TranscriptFile.parse(trimmed, extension: "lrc")
        }

        var segments: [TranscriptSegment] = []
        var start: Double?
        var words: [String] = []
        func flush() {
            if let start, !words.isEmpty {
                segments.append(TranscriptSegment(start: start, text: words.joined(separator: " ")))
            }
            words = []
        }
        for raw in trimmed.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isSpokenDuration(line) else { continue }
            if let (time, rest) = leadingTimestamp(line) {
                flush()
                start = time
                if !rest.isEmpty { words.append(rest) }
            } else if start != nil {
                words.append(line)
            }
        }
        flush()
        return TranscriptSegment.normalized(segments)
    }


    /// `1:05`, `01:02:03`, optionally followed by the words on the same line.
    private static func leadingTimestamp(_ line: String) -> (Double, String)? {
        guard let match = line.range(of: #"^(\d{1,2}:)?\d{1,2}:\d{2}(?=\s|$)"#, options: .regularExpression) else { return nil }
        let parts = line[match].split(separator: ":").compactMap { Double($0) }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return (seconds, line[match.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    private static func isSpokenDuration(_ line: String) -> Bool {
        line.range(
            of: #"^\d+ (hours?|minutes?|seconds?)(, \d+ (hours?|minutes?|seconds?))*$"#,
            options: .regularExpression
        ) != nil
    }
}
