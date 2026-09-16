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
        try dbQueue.write { db in try record.save(db) }
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
        let replacedSpans = accepted.map { $0.start...max($0.end, $0.start) }
        let kept = existing.filter { segment in
            segment.isEdited || !replacedSpans.contains { $0.overlaps(segment.start...max(segment.end, segment.start)) }
        }
        return TranscriptSegment.normalized(kept + accepted)
    }

    func find(trackID: String) throws -> [TranscriptSegment]? {
        try dbQueue.read { db in
            guard let record = try TranscriptRecord.fetchOne(db, key: trackID) else { return nil }
            let segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(record.segmentsJSON.utf8))
            return TranscriptSegment.normalized(segments)
        }
    }

    func delete(trackID: String) throws {
        try dbQueue.write { db in _ = try TranscriptRecord.deleteOne(db, key: trackID) }
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
    func recentEdits(limit: Int = 200) throws -> [TranscriptEdit] {
        try dbQueue.read { db in
            try TranscriptEdit.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }

    private func existingCreatedAt(trackID: String) throws -> Date? {
        try dbQueue.read { db in try TranscriptRecord.fetchOne(db, key: trackID)?.createdAt }
    }
}
