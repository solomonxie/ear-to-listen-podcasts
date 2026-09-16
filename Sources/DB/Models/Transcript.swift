import Foundation
import GRDB

/// One timestamped line of a transcript. No speaker field — neither Apple's on-device
/// recognizer nor OpenAI's transcription endpoint diarizes speakers.
///
/// `end` is what makes partial transcripts work: segments carry the time span they cover,
/// so `TranscriptCoverage` can tell which stretches of an episode still need transcribing
/// and only those get sent out. Older rows (and demo data) predate it — `normalized`
/// backfills them on read.
struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// `TranscriptionEngineKind.rawValue` of whatever produced this line.
    var engine: String?
    var isEdited: Bool

    var id: Double { start }

    init(start: Double, end: Double? = nil, text: String, engine: String? = nil, isEdited: Bool = false) {
        self.start = start
        self.end = end ?? start
        self.text = text
        self.engine = engine
        self.isEdited = isEdited
    }

    // Segments live as JSON inside `transcripts.segmentsJSON`, so rows written before
    // `end`/`engine`/`isEdited` existed still have to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end) ?? start
        text = try container.decode(String.self, forKey: .text)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
    }

    /// Sorts by time and gives every segment a usable span — an unset `end` becomes the
    /// next line's start, and the last line gets a short tail.
    static func normalized(_ segments: [TranscriptSegment], tailSeconds: Double = 4) -> [TranscriptSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, segment in
            guard segment.end <= segment.start else { return segment }
            var filled = segment
            filled.end = index + 1 < sorted.count ? sorted[index + 1].start : segment.start + tailSeconds
            return filled
        }
    }
}

struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcripts"

    var trackID: String
    var segmentsJSON: String
    var createdAt: Date
    /// Last engine to contribute — a transcript can mix engines when one filled the gaps
    /// another left behind.
    var engine: String?
    var updatedAt: Date?
}

/// One correction the user made to a transcript line, kept after the fact rather than
/// overwritten in place: it's both the audit trail behind "see my edits" and the
/// vocabulary hint (`TranscriptionContext`) handed to the next transcription request, so
/// the same name/term stops coming back wrong.
struct TranscriptEdit: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "transcriptEdits"

    var id: String
    var trackID: String
    var segmentStart: Double
    var originalText: String
    var editedText: String
    var createdAt: Date
}
