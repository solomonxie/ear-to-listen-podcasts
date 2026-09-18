import Foundation
import GRDB

struct TranscriptStore {
    let dbQueue: DatabaseQueue

    func save(trackID: String, segments: [TranscriptSegment], engine: String? = nil) throws {
        let normalized = TranscriptSegment.normalized(segments)
        let json = try JSONEncoder().encode(normalized)
        let record = TranscriptRecord(
            trackID: trackID,
            segmentsJSON: String(decoding: json, as: UTF8.self),
            createdAt: (try? existingCreatedAt(trackID: trackID)) ?? Date(),
            engine: engine,
            updatedAt: Date()
        )
        let previous = try dbQueue.write { db -> Int? in
            let previous = try TranscriptRecord.fetchOne(db, key: trackID)
            try record.save(db)
            return previous.map { $0.segmentsJSON.count }
        }
        // Counts, not the text: a transcript is tens of thousands of words, and the log is
        // there to say what happened and when, not to hold a second copy of the library.
        ChangeLog.record(
            "transcripts", key: trackID,
            old: previous.map { ["characters": $0] },
            new: ["characters": record.segmentsJSON.count, "segments": normalized.count],
            in: dbQueue
        )
    }

    /// Folds a freshly transcribed window into what's already stored. A user-edited line
    /// always wins over an incoming one covering the same span — re-transcribing a gap
    /// next to a correction must not silently undo it.
    @discardableResult
    func merge(trackID: String, incoming: [TranscriptSegment], engine: String? = nil) throws -> [TranscriptSegment] {
        let existing = (try find(trackID: trackID)) ?? []
        let merged = Self.merging(existing: existing, incoming: incoming)
        try save(trackID: trackID, segments: merged, engine: engine)
        return merged
    }

    static func merging(existing: [TranscriptSegment], incoming: [TranscriptSegment]) -> [TranscriptSegment] {
        let protectedSpans = existing.filter(\.isEdited).map { $0.start...max($0.end, $0.start) }
        let accepted = incoming.filter { segment in
            !protectedSpans.contains { $0.contains(segment.start) }
        }
        // Only text replaces what's there. An empty segment is a silence marker — it
        // records that a stretch was listened to, not what was said in it — and a window
        // that came back thinner than what's already stored (a recognizer that dropped
        // half of it, an engine swapped mid-episode) must not be able to delete lines by
        // claiming their time as silence.
        let spoken = accepted.filter { !$0.text.isEmpty }
        let replacedSpans = spoken.map { $0.start...max($0.end, $0.start) }
        let kept = existing.filter { segment in
            segment.isEdited || !replacedSpans.contains { $0.overlaps(segment.start...max(segment.end, segment.start)) }
        }
        let silence = clipping(
            accepted.filter(\.text.isEmpty), around: (kept + spoken).filter { !$0.text.isEmpty }
        )
        return TranscriptSegment.normalized(kept + spoken + silence)
    }

    /// Cuts the stretches that do have text out of each silence marker, so it claims only
    /// what nobody spoke in. Anything left shorter than a breath isn't worth recording.
    private static func clipping(
        _ silence: [TranscriptSegment], around spoken: [TranscriptSegment], minimum: Double = 0.5
    ) -> [TranscriptSegment] {
        guard !silence.isEmpty else { return [] }
        let spans = TranscriptCoverage.covered(spoken)
        return silence.flatMap { marker -> [TranscriptSegment] in
            var pieces: [TranscriptSegment] = []
            var cursor = marker.start
            for span in spans where span.end > marker.start && span.start < marker.end {
                if span.start - cursor >= minimum {
                    pieces.append(TranscriptSegment(start: cursor, end: span.start, text: "", engine: marker.engine))
                }
                cursor = max(cursor, span.end)
            }
            if marker.end - cursor >= minimum {
                pieces.append(TranscriptSegment(start: cursor, end: marker.end, text: "", engine: marker.engine))
            }
            return pieces
        }
    }

    func find(trackID: String) throws -> [TranscriptSegment]? {
        try dbQueue.read { db in
            guard let record = try TranscriptRecord.fetchOne(db, key: trackID) else { return nil }
            let segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(record.segmentsJSON.utf8))
            return TranscriptSegment.normalized(segments)
        }
    }

    /// Every stored transcript, for backup. Returns the raw rows rather than segments so
    /// the caller keeps the engine/updatedAt alongside them.
    func allRecords() throws -> [TranscriptRecord] {
        try dbQueue.read { db in try TranscriptRecord.fetchAll(db) }
    }

    func delete(trackID: String) throws {
        let old: Int? = try dbQueue.write { db in
            let old = try TranscriptRecord.fetchOne(db, key: trackID)?.segmentsJSON.count
            _ = try TranscriptRecord.deleteOne(db, key: trackID)
            return old
        }
        ChangeLog.record("transcripts", key: trackID, old: old.map { ["characters": $0] }, in: dbQueue)
    }

    // MARK: Edits

    /// Rewrites one line and files the correction away. Returns the updated transcript.
    @discardableResult
    func applyEdit(trackID: String, segmentStart: Double, newText: String) throws -> [TranscriptSegment] {
        var segments = (try find(trackID: trackID)) ?? []
        guard let index = segments.firstIndex(where: { $0.start == segmentStart }) else { return segments }
        let originalText = segments[index].text
        guard originalText != newText else { return segments }

        segments[index].text = newText
        segments[index].isEdited = true
        try save(trackID: trackID, segments: segments)

        let edit = TranscriptEdit(
            id: UUID().uuidString,
            trackID: trackID,
            segmentStart: segmentStart,
            originalText: originalText,
            editedText: newText,
            createdAt: Date()
        )
        try dbQueue.write { db in try edit.insert(db) }
        // The one place the log holds the text itself: a correction is a line long, and
        // it's hand-typed — the most expensive thing per byte in the whole library.
        ChangeLog.record(
            "transcriptEdits", key: "\(trackID)@\(segmentStart)",
            old: ["text": originalText], new: ["text": newText], in: dbQueue
        )
        return segments
    }

    func edits(trackID: String) throws -> [TranscriptEdit] {
        try dbQueue.read { db in
            try TranscriptEdit
                .filter(Column("trackID") == trackID)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Recent corrections across the whole library — vocabulary the user has already
    /// fixed once is worth hinting at even on an episode they haven't edited yet.
    /// Puts corrections back after a restore, keeping their original ids so restoring the
    /// same backup twice doesn't duplicate them.
    func restoreEdits(_ edits: [TranscriptEdit]) throws {
        try dbQueue.write { db in
            for edit in edits where try TranscriptEdit.fetchOne(db, key: edit.id) == nil {
                try edit.insert(db)
            }
        }
    }

    func recentEdits(limit: Int = 200) throws -> [TranscriptEdit] {
        try dbQueue.read { db in
            try TranscriptEdit.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    private func existingCreatedAt(trackID: String) throws -> Date? {
        try dbQueue.read { db in try TranscriptRecord.fetchOne(db, key: trackID)?.createdAt }
    }
}
