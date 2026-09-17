import Foundation

struct TimeWindow: Equatable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Works out which stretches of an episode still have no transcript. This is what keeps a
/// partial transcript useful: whatever's already stored is never sent out again, so
/// resuming an episode picks up at the first hole instead of re-transcribing (and
/// re-paying for) the whole file.
enum TranscriptCoverage {
    /// A hole shorter than this isn't worth a request — it's the natural pause between
    /// two segments, not missing text.
    static let minimumGapSeconds: Double = 5

    static func covered(_ segments: [TranscriptSegment]) -> [TimeWindow] {
        let spans = segments
            .map { TimeWindow(start: $0.start, end: max($0.end, $0.start)) }
            .sorted { $0.start < $1.start }
        return spans.reduce(into: [TimeWindow]()) { merged, span in
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
    }

    static func coveredSeconds(_ segments: [TranscriptSegment]) -> Double {
        covered(segments).reduce(0) { $0 + $1.duration }
    }

    static func gaps(
        in segments: [TranscriptSegment],
        duration: Double,
        minimumGap: Double = minimumGapSeconds
    ) -> [TimeWindow] {
        guard duration > 0 else { return [] }
        var gaps: [TimeWindow] = []
        var cursor: Double = 0
        for span in covered(segments) where span.end > 0 {
            if span.start - cursor >= minimumGap {
                gaps.append(TimeWindow(start: cursor, end: min(span.start, duration)))
            }
            cursor = max(cursor, span.end)
        }
        if duration - cursor >= minimumGap {
            gaps.append(TimeWindow(start: cursor, end: duration))
        }
        return gaps.filter { $0.duration >= minimumGap }
    }

    /// The gaps, chopped into request-sized windows and reordered so the one the listener
    /// is about to reach is transcribed first — everything earlier gets filled in after.
    static func windows(
        in segments: [TranscriptSegment],
        duration: Double,
        windowSeconds: Double,
        from playhead: Double = 0,
        minimumGap: Double = minimumGapSeconds
    ) -> [TimeWindow] {
        let chunks = gaps(in: segments, duration: duration, minimumGap: minimumGap).flatMap { gap in
            stride(from: gap.start, to: gap.end, by: windowSeconds).map { start in
                TimeWindow(start: start, end: min(start + windowSeconds, gap.end))
            }
        }
        let ahead = chunks.filter { $0.end > playhead }
        let behind = chunks.filter { $0.end <= playhead }
        return ahead + behind
    }

    /// Whether a window already being worked on is still the one worth spending on.
    ///
    /// Drifting forward out of it isn't enough on its own — it's only dropped once the
    /// playhead has left it by a clear margin *and* a different stretch now wants doing
    /// first. Without that second half, a playhead parked in an already-transcribed part
    /// of the episode would keep cancelling the distant window it's waiting on.
    static func isWorthFinishing(
        _ window: TimeWindow,
        in segments: [TranscriptSegment],
        duration: Double,
        windowSeconds: Double,
        playhead: Double
    ) -> Bool {
        let grace = windowSeconds
        guard playhead < window.start - grace || playhead > window.end + grace else { return true }
        let next = windows(in: segments, duration: duration, windowSeconds: windowSeconds, from: playhead).first
        return next == nil || next == window
    }
}
