import Foundation

struct TrackMatch {
    var track: Track
    var confidence: Double
}

enum TrackMatcher {
    /// Matches are graded, not binary: callers should only auto-accept matches
    /// above a high threshold and surface the rest for manual confirmation.
    static let autoAcceptThreshold = 0.85

    static func bestMatch(for imported: ImportedTrack, in library: [Track], artistNames: [String: String]) -> TrackMatch? {
        var best: TrackMatch?
        for track in library {
            let score = score(imported: imported, track: track, artistName: track.artistID.flatMap { artistNames[$0] })
            if best == nil || score > best!.confidence {
                best = TrackMatch(track: track, confidence: score)
            }
        }
        return best
    }

    private static func score(imported: ImportedTrack, track: Track, artistName: String?) -> Double {
        let titleScore = similarity(normalize(imported.title), normalize(track.title))
        let artistScore = artistName.map { similarity(normalize(imported.artist), normalize($0)) } ?? 0
        var total = titleScore * 0.7 + artistScore * 0.3

        if let importedMs = imported.durationMs, let trackMs = track.durationMs {
            let deltaSeconds = abs(importedMs - trackMs) / 1000
            if deltaSeconds > 3 {
                total *= 0.5
            }
        }
        return total
    }

    private static func normalize(_ string: String) -> String {
        var result = string.lowercased()
        for suffix in ["(feat.", "(ft.", "feat.", "ft."] {
            if let range = result.range(of: suffix) {
                result = String(result[result.startIndex..<range.lowerBound])
            }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        result = String(result.unicodeScalars.filter { allowed.contains($0) })
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 1.0 = identical, 0.0 = completely different, based on normalized Levenshtein distance.
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let distance = levenshteinDistance(Array(a), Array(b))
        let maxLength = max(a.count, b.count)
        guard maxLength > 0 else { return 1 }
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
