import Foundation
import GRDB

struct TranscriptStore {
    let dbQueue: DatabaseQueue

    func save(trackID: String, segments: [TranscriptSegment]) throws {
        let json = try JSONEncoder().encode(segments)
        let record = TranscriptRecord(
            trackID: trackID, segmentsJSON: String(decoding: json, as: UTF8.self), createdAt: Date()
        )
        try dbQueue.write { db in try record.save(db) }
    }

    func find(trackID: String) throws -> [TranscriptSegment]? {
        try dbQueue.read { db in
            guard let record = try TranscriptRecord.fetchOne(db, key: trackID) else { return nil }
            return try JSONDecoder().decode([TranscriptSegment].self, from: Data(record.segmentsJSON.utf8))
        }
    }

    func delete(trackID: String) throws {
        try dbQueue.write { db in _ = try TranscriptRecord.deleteOne(db, key: trackID) }
    }
}
