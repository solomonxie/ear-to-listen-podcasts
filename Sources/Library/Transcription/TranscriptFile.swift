import Foundation

/// Transcripts as plain sidecar files sitting beside the audio — `episode.mp3` next to
/// `episode.vtt` — rather than only inside this app's database.
///
/// Two directions, deliberately asymmetric:
///
/// **Reading is liberal.** Plenty of podcasts already ship a transcript, and whatever the
/// host handed over is what's in the bucket. Finding one means an episode is transcribed
/// the moment it syncs — no battery, no API spend, nothing to wait for.
///
/// **Writing is strict**: WebVTT, plus an `.lrc` copy for lyrics-aware players. VTT is the
/// canonical one because it's the only common format carrying an *end* time per line, and
/// end times are what `TranscriptCoverage` reads to know which stretches are done. LRC has
/// line starts only, so a transcript round-tripped through it alone would forget which
/// stretches were listened to and found silent, and re-transcribe them forever.
enum TranscriptFile {
    /// Read in this order — the earlier ones carry more of what we need.
    static let readableExtensions = ["vtt", "srt", "json", "lrc", "txt"]

    /// Written together: VTT is read back, LRC is a courtesy for other players.
    static let canonicalExtension = "vtt"
    static let companionExtension = "lrc"

    /// Every format this app can write. The two above go up whenever a transcript is
    /// uploaded; the rest are only ever *rewritten* — an episode whose folder already
    /// holds an `.srt` gets that file replaced too, because a stale copy of the same
    /// transcript, in another format, beside the fresh one is exactly the confusion
    /// uploading is meant to end.
    static let writableExtensions = [canonicalExtension, companionExtension, "srt", "json", "txt"]

    /// `podcast/ep1.mp3` → `podcast/ep1.vtt`. Matching on basename is the whole convention.
    ///
    /// A path with nothing left once its extension is off has no sidecar name to give, and
    /// the answer to that is nothing — the old fallback returned the audio path itself,
    /// which is the one string this must never hand to a writer.
    static func sidecarPath(forAudioPath path: String, extension ext: String) -> String? {
        let base = (path as NSString).deletingPathExtension
        return base.isEmpty ? nil : "\(base).\(ext)"
    }

    /// Pairs each audio path in a listing with the transcript beside it, matched on
    /// basename. Built once per sync from the listing we already have, so opening an
    /// episode costs no probing — and so "there is no transcript" is a fact we know
    /// rather than five failed requests.
    ///
    /// `readableExtensions` is in preference order, so a folder holding both `.vtt` and
    /// `.txt` for one episode yields the `.vtt`.
    static func sidecarsByAudioPath(in files: [CloudFile]) -> [String: String] {
        var byStem: [String: String] = [:]
        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard readableExtensions.contains(ext) else { continue }
            let stem = (file.path as NSString).deletingPathExtension
            let existing = byStem[stem].map { ($0 as NSString).pathExtension.lowercased() }
            let rank = readableExtensions.firstIndex(of: ext) ?? .max
            let existingRank = existing.flatMap { readableExtensions.firstIndex(of: $0) } ?? .max
            if rank < existingRank { byStem[stem] = file.path }
        }

        var byAudio: [String: String] = [:]
        for file in files where FileKind(path: file.path).isPlayable {
            let stem = (file.path as NSString).deletingPathExtension
            if let sidecar = byStem[stem] { byAudio[file.path] = sidecar }
        }
        return byAudio
    }

    static func candidatePaths(forAudioPath path: String) -> [String] {
        readableExtensions.compactMap { sidecarPath(forAudioPath: path, extension: $0) }
    }

    // MARK: Reading

    /// `duration` is only needed by formats that carry no timings at all (`.txt`), where
    /// the text is spread across the episode so it's at least searchable and orderable.
    static func parse(_ text: String, extension ext: String, duration: Double? = nil) -> [TranscriptSegment] {
        let segments: [TranscriptSegment]
        switch ext.lowercased() {
        case "vtt": segments = parseVTT(text)
        case "srt": segments = parseSRT(text)
        case "lrc": segments = parseLRC(text)
        case "json": segments = parseJSON(text)
        case "txt": segments = parsePlainText(text, duration: duration)
        default: segments = []
        }
        return TranscriptSegment.normalized(segments)
    }

    /// Our own marker word in a `NOTE` block. What's read back doesn't depend on it —
    /// the parser looks for `silence`, `edited` and `engine=` in any NOTE — so files
    /// written under the app's old name still read correctly.
    static let noteTag = "ear-to-listen"

    /// `NOTE ear-to-listen silence <start> --> <end>` marks a stretch that was listened to with
    /// nothing said. Other players ignore NOTE blocks; we need them, or those stretches
    /// read as gaps and get transcribed again on every pass.
    private static func parseVTT(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var engine: String?
        var isEdited = false

        for block in blocks(in: text) {
            var lines = block
            guard let first = lines.first else { continue }

            if first.hasPrefix("WEBVTT") { continue }
            if first.hasPrefix("NOTE") {
                let note = lines.joined(separator: " ")
                if let span = timeSpan(in: note), note.contains("silence") {
                    segments.append(TranscriptSegment(start: span.0, end: span.1, text: "", engine: engine))
                }
                if let found = value(of: "engine", in: note) { engine = found }
                if note.contains("edited") { isEdited = true }
                continue
            }
            // An optional cue identifier can precede the timing line.
            if timeSpan(in: first) == nil { lines = Array(lines.dropFirst()) }
            guard let timing = lines.first, let span = timeSpan(in: timing) else { continue }

            let body = lines.dropFirst().joined(separator: " ")
            let stripped = strippingInlineTimestamps(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            segments.append(TranscriptSegment(
                start: span.0, end: span.1, text: stripped, engine: engine, isEdited: isEdited
            ))
            isEdited = false
        }
        return segments
    }

    private static func parseSRT(_ text: String) -> [TranscriptSegment] {
        blocks(in: text).compactMap { block in
            var lines = block
            // SRT blocks open with a sequence number.
            if let first = lines.first, timeSpan(in: first) == nil { lines = Array(lines.dropFirst()) }
            guard let timing = lines.first, let span = timeSpan(in: timing) else { return nil }
            let body = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return TranscriptSegment(start: span.0, end: span.1, text: body)
        }
    }

    /// `[mm:ss.xx]text`, with the usual `[ti:]`/`[ar:]` header tags skipped. A line can
    /// carry several timestamps, meaning the same text repeats at each. No end times —
    /// `normalized` backfills them from the following line.
    private static func parseLRC(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            var rest = Substring(raw)
            var stamps: [Double] = []

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = lrcTimestamp(String(tag)) { stamps.append(seconds) }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }

            let body = strippingInlineTimestamps(String(rest)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            for stamp in stamps {
                segments.append(TranscriptSegment(start: stamp, text: body))
            }
        }
        return segments
    }

    /// The Podcast Index transcript shape (`application/json`).
    private static func parseJSON(_ text: String) -> [TranscriptSegment] {
        struct Document: Decodable {
            struct Segment: Decodable {
                var startTime: Double?
                var endTime: Double?
                var body: String?
                var speaker: String?
            }
            var segments: [Segment]?
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: Data(text.utf8)),
              let segments = document.segments else { return [] }
        return segments.compactMap { segment in
            guard let start = segment.startTime,
                  let body = segment.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return nil }
            // Speaker names aren't modelled on `TranscriptSegment`, so they ride along in
            // the text rather than being dropped.
            let text = segment.speaker.map { "\($0): \(body)" } ?? body
            return TranscriptSegment(start: start, end: segment.endTime ?? start, text: text)
        }
    }

    /// No timings at all. Sentences are spread across the episode by length — enough to
    /// read and search, never accurate enough to seek by.
    private static func parsePlainText(_ text: String, duration: Double?) -> [TranscriptSegment] {
        guard let duration, duration > 0 else { return [] }
        return interpolated(text, over: TimeWindow(start: 0, end: duration), engine: nil)
    }

    /// Spreads untimed text across a window in proportion to how long each piece is.
    /// Approximate by construction; used for plain-text imports and for engines that
    /// return text without timings.
    static func interpolated(_ text: String, over window: TimeWindow, engine: String?) -> [TranscriptSegment] {
        let pieces = sentences(in: text)
        let total = pieces.reduce(0) { $0 + $1.count }
        guard total > 0, window.duration > 0 else { return [] }

        var segments: [TranscriptSegment] = []
        var cursor = window.start
        for (index, piece) in pieces.enumerated() {
            let share = window.duration * Double(piece.count) / Double(total)
            // The last piece lands exactly on the window's end, so the span is gapless
            // however the rounding fell.
            let end = index == pieces.count - 1 ? window.end : min(window.end, cursor + share)
            segments.append(TranscriptSegment(start: cursor, end: max(end, cursor), text: piece, engine: engine))
            cursor = end
        }
        return segments
    }

    private static func sentences(in text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(current.trimmed()) }
                current = ""
                continue
            }
            current.append(character)
            if ".!?。！？".contains(character) {
                pieces.append(current.trimmed())
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(current.trimmed()) }
        return pieces.filter { !$0.isEmpty }
    }

    // MARK: Writing

    /// WebVTT, with our own extras in `NOTE` blocks so other players see a plain caption
    /// file and we still get back the engine, the corrections, and the silent stretches.
    static func vtt(from segments: [TranscriptSegment]) -> String {
        var out = ["WEBVTT", ""]
        if let engine = segments.compactMap(\.engine).first {
            out.append("NOTE \(noteTag) engine=\(engine)")
            out.append("")
        }
        for segment in TranscriptSegment.normalized(segments) {
            guard !segment.text.isEmpty else {
                out.append("NOTE \(noteTag) silence \(vttTime(segment.start)) --> \(vttTime(segment.end))")
                out.append("")
                continue
            }
            if segment.isEdited {
                out.append("NOTE \(noteTag) edited")
                out.append("")
            }
            out.append("\(vttTime(segment.start)) --> \(vttTime(segment.end))")
            out.append(segment.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The companion copy. Silent stretches and end times don't survive — that's why it's
    /// the companion and not the canonical one.
    static func lrc(from segments: [TranscriptSegment], title: String? = nil, artist: String? = nil) -> String {
        var out: [String] = []
        if let title { out.append("[ti:\(title)]") }
        if let artist { out.append("[ar:\(artist)]") }
        out.append("[by:Ear to Listen]")
        for segment in TranscriptSegment.normalized(segments) where !segment.text.isEmpty {
            out.append("[\(lrcTime(segment.start))]\(segment.text)")
        }
        return out.joined(separator: "\n")
    }

    /// The transcript in one format, by extension. Anything unrecognised comes back as
    /// VTT — the canonical one, and the only one read back.
    static func text(
        from segments: [TranscriptSegment], extension ext: String,
        title: String? = nil, artist: String? = nil
    ) -> String {
        switch ext.lowercased() {
        case companionExtension: return lrc(from: segments, title: title, artist: artist)
        case "srt": return srt(from: segments)
        case "json": return json(from: segments)
        case "txt": return plainText(from: segments)
        default: return vtt(from: segments)
        }
    }

    static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case canonicalExtension: return "text/vtt"
        case "json": return "application/json"
        case "srt": return "application/x-subrip"
        default: return "text/plain"
        }
    }

    /// Numbered cues and a comma before the milliseconds — the two things that make this
    /// SRT rather than VTT. Our `NOTE` extras have nowhere to go in this format, which is
    /// why it is a rewrite target and never the copy read back.
    static func srt(from segments: [TranscriptSegment]) -> String {
        var out: [String] = []
        for (index, segment) in TranscriptSegment.normalized(segments).filter({ !$0.text.isEmpty }).enumerated() {
            out.append("\(index + 1)")
            out.append("\(srtTime(segment.start)) --> \(srtTime(segment.end))")
            out.append(segment.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The Podcast Index transcript shape, the one `parseJSON` reads.
    static func json(from segments: [TranscriptSegment]) -> String {
        let lines = TranscriptSegment.normalized(segments).filter { !$0.text.isEmpty }
        let body = lines.map { segment in
            ["startTime": segment.start, "endTime": segment.end, "body": segment.text] as [String: Any]
        }
        let document: [String: Any] = ["version": "1.0.0", "segments": body]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// No timings at all — the words, in order. What `parsePlainText` spreads back over
    /// the episode when it's the only file there.
    static func plainText(from segments: [TranscriptSegment]) -> String {
        TranscriptSegment.normalized(segments).filter { !$0.text.isEmpty }.map(\.text).joined(separator: "\n")
    }

    // MARK: Time formats

    static func vttTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    static func srtTime(_ seconds: Double) -> String {
        vttTime(seconds).replacingOccurrences(of: ".", with: ",")
    }

    /// LRC counts in minutes, which for a podcast routinely runs past 59 — `[83:20.50]` is
    /// valid and is what players expect.
    static func lrcTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let centis = Int((total - total.rounded(.down)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, centis)
    }

    // MARK: Parsing helpers

    /// Blank-line separated blocks, with CRLF and a BOM tolerated.
    private static func blocks(in text: String) -> [[String]] {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        return cleaned.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(whereSeparator: \.isNewline).map { $0.trimmed() }.filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines
        }
    }

    /// `00:00:01.000 --> 00:00:04.000`, also accepting SRT's comma and a missing hour.
    ///
    /// Takes the token nearest the arrow on each side, because neither end is necessarily
    /// alone on its line: our own `NOTE ear-to-listen silence` prefixes the start, and cue settings
    /// (`align:start`) trail the end.
    private static func timeSpan(in line: String) -> (Double, Double)? {
        guard let range = line.range(of: "-->") else { return nil }
        guard let before = line[line.startIndex..<range.lowerBound].split(whereSeparator: \.isWhitespace).last,
              let after = line[range.upperBound...].split(whereSeparator: \.isWhitespace).first,
              let start = clockTime(String(before)),
              let end = clockTime(String(after)) else { return nil }
        return (start, end)
    }

    private static func clockTime(_ raw: String) -> Double? {
        let token = raw.trimmed().replacingOccurrences(of: ",", with: ".")
        let parts = token.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        return parts.count == 3
            ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
            : numbers[0] * 60 + numbers[1]
    }

    /// `mm:ss.xx` inside an LRC bracket. Header tags like `ti:` aren't times.
    private static func lrcTimestamp(_ tag: String) -> Double? {
        guard let first = tag.first, first.isNumber else { return nil }
        return clockTime(tag)
    }

    /// Enhanced-LRC (`<00:12.30>`) and VTT (`<00:00:12.300>`) per-word timings — read past
    /// them rather than letting them land in the text.
    private static func strippingInlineTimestamps(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "<" { depth += 1; continue }
            if character == ">" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(character) }
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    private static func value(of key: String, in note: String) -> String? {
        guard let range = note.range(of: "\(key)=") else { return nil }
        let rest = note[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}

private extension StringProtocol {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
