import Foundation

/// The summary is plain text the listener can edit, with one piece of markup: a `[12:34]`
/// marker is a moment in the episode. That's the whole format — no headings, no JSON, no
/// second editor — because a summary someone can't retype in their own words is a summary
/// they can only delete.
///
/// The markers are what make it worth reading *while* an episode is on: each take-away
/// says when it was said, and tapping the time plays from there.
enum EpisodeSummary {
    /// `eartolisten-seek://87.5`. A URL rather than a button per run, so a marker can sit
    /// mid-sentence and still wrap with the text around it — `Text` lays out links, and a
    /// row of buttons doesn't flow.
    static let seekScheme = "eartolisten-seek"

    private static let markerPattern = try? NSRegularExpression(
        pattern: #"\[(\d{1,3}:\d{2}(?::\d{2})?)\]"#
    )

    static func marker(for seconds: TimeInterval) -> String {
        "[\(Scrubber.formatted(seconds))]"
    }

    /// `12:34` / `1:02:03` → seconds. Nil for anything that isn't a time.
    static func seconds(inMarker text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.reduce(0) { total, part in total * 60 + TimeInterval(Int(part) ?? 0) }
    }

    static func seconds(inURL url: URL) -> TimeInterval? {
        guard url.scheme == seekScheme else { return nil }
        // `scheme://87.5` puts the number in the host, `scheme:87.5` in the path.
        return TimeInterval(url.host ?? url.absoluteString.replacingOccurrences(of: "\(seekScheme)://", with: ""))
    }

    /// The text with every marker turned into a tappable link. Everything else is left
    /// exactly as written — including whatever the listener typed over the top of it.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let markerPattern else { return result }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        // Back to front, so replacing one marker doesn't move the ones after it.
        for match in markerPattern.matches(in: text, range: full).reversed() {
            guard let range = Range(match.range, in: text),
                  let timeRange = Range(match.range(at: 1), in: text),
                  let seconds = seconds(inMarker: String(text[timeRange])),
                  let url = URL(string: "\(seekScheme)://\(seconds)"),
                  let attributedRange = Range(range, in: result) else { continue }
            var marker = AttributedString(String(text[timeRange]))
            marker.link = url
            marker.font = .footnote.monospacedDigit().weight(.semibold)
            result.replaceSubrange(attributedRange, with: marker)
        }
        return result
    }

    /// What the model sends back, in the shape the card renders: a few lines of what the
    /// episode is, the moments worth going back to, and — only when the episode actually
    /// lands somewhere — what it concluded.
    ///
    /// **Decoded by hand, leniently**, for the same reason `EpisodeMetadataSuggester`'s
    /// suggestion is: models answer this prompt in several near-misses — a time as
    /// `125` instead of `"2:05"`, a point as a bare string, a term as `{"name": …}` —
    /// and a synthesized decoder throws the whole reply away over any one of them. The
    /// summary is the most expensive call this app makes; it shouldn't be discarded over
    /// a quotation mark.
    struct Draft: Decodable {
        struct Point {
            var time: String?
            var text: String?
        }
        var brief: String?
        var points: [Point]?
        var conclusion: String?
        var terms: [String]?

        init(brief: String? = nil, points: [Point]? = nil, conclusion: String? = nil, terms: [String]? = nil) {
            self.brief = brief
            self.points = points
            self.conclusion = conclusion
            self.terms = terms
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            brief = Self.string(container, .brief) ?? Self.string(container, .summary)
            conclusion = Self.string(container, .conclusion)
            points = (try? container.decode([Flexible.Point].self, forKey: .points))?
                .map { Point(time: $0.time, text: $0.text) }
            terms = (try? container.decode([Flexible.Named].self, forKey: .terms))?
                .compactMap(\.name)
        }

        private enum CodingKeys: String, CodingKey {
            case brief, summary, points, conclusion, terms
        }

        private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            (try? container.decode(String.self, forKey: key))?.trimmed.nilIfEmpty
        }
    }

    /// The near-misses, decoded. Each of these accepts the shape that was asked for and
    /// the shapes that keep arriving instead.
    private enum Flexible {
        /// `{"time": "2:05", "text": …}`, `{"time": 125, …}`, `{"start": …}`, or just
        /// `"2:05 — what was said"`.
        struct Point: Decodable {
            var time: String?
            var text: String?

            init(from decoder: Decoder) throws {
                if let line = try? decoder.singleValueContainer().decode(String.self) {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    if let first = parts.first, seconds(inMarker: first.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) != nil {
                        time = first.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        text = parts.count > 1 ? parts[1].trimmed : nil
                    } else {
                        text = line.trimmed
                    }
                    return
                }
                let container = try decoder.container(keyedBy: Key.self)
                text = (try? container.decode(String.self, forKey: .text))
                    ?? (try? container.decode(String.self, forKey: .point))
                if let stamp = (try? container.decode(String.self, forKey: .time))
                            ?? (try? container.decode(String.self, forKey: .start)) {
                    time = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                } else if let raw = (try? container.decode(Double.self, forKey: .time))
                            ?? (try? container.decode(Double.self, forKey: .start)) {
                    // Seconds, because it was told to copy a prefix and did arithmetic.
                    time = Scrubber.formatted(raw)
                }
            }

            private enum Key: String, CodingKey { case time, start, text, point }
        }

        /// `"melatonin"` or `{"name": "melatonin"}` / `{"term": …}`.
        struct Named: Decodable {
            var name: String?

            init(from decoder: Decoder) throws {
                if let plain = try? decoder.singleValueContainer().decode(String.self) {
                    name = plain.trimmed.nilIfEmpty
                    return
                }
                let container = try decoder.container(keyedBy: Key.self)
                name = ((try? container.decode(String.self, forKey: .name))
                        ?? (try? container.decode(String.self, forKey: .term)))?.trimmed.nilIfEmpty
            }

            private enum Key: String, CodingKey { case name, term }
        }
    }

    /// A reply that isn't JSON at all, kept rather than thrown away. Models drop the
    /// format on long prompts and answer in prose — which is a perfectly good summary,
    /// just without the times or the terms. The fences and any "Here's a summary:"
    /// preamble go; the rest is what the listener paid for.
    static func prose(in reply: String) -> String? {
        let cleaned = reply
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmed
        guard cleaned.count > 40, !cleaned.hasPrefix("{"), !cleaned.hasPrefix("[") else { return nil }
        return cleaned
    }

    /// Flattens a draft into the one editable blob that gets stored. Points keep their
    /// times as markers; a point the model gave no time for still earns its line.
    static func text(from draft: Draft) -> String {
        var blocks: [String] = []
        if let brief = draft.brief?.trimmed.nilIfEmpty { blocks.append(brief) }
        let points = (draft.points ?? []).compactMap { point -> String? in
            guard let text = point.text?.trimmed.nilIfEmpty else { return nil }
            guard let time = point.time?.trimmed, seconds(inMarker: time) != nil else { return "• \(text)" }
            return "• [\(time)] \(text)"
        }
        if !points.isEmpty { blocks.append(points.joined(separator: "\n")) }
        if let conclusion = draft.conclusion?.trimmed.nilIfEmpty { blocks.append(conclusion) }
        return blocks.joined(separator: "\n\n")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
