import Foundation
import GRDB

/// One timestamped line of a transcript. No speaker field — OpenAI's transcription
/// endpoint returns plain segments, not diarized speakers.
struct TranscriptSegment: Codable, Hashable {
    var start: Double
    var text: String
}

struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcripts"

    var trackID: String
    var segmentsJSON: String
    var createdAt: Date
}
