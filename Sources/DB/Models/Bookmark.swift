import Foundation
import GRDB

/// A moment in an episode, saved with one tap while listening. No title is asked for:
/// the point is to mark the place before it goes past, and a prompt at that moment is
/// the reason nobody marks anything. Notes, tags and the line that was being spoken are
/// all editable afterwards, when there's time to type.
struct Bookmark: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "bookmarks"

    var id: String
    var trackID: String
    var positionMs: Int
    var note: String?
    /// Comma-separated; use `tagList` to read them.
    var tags: String?
    /// What was being said there, copied when the mark was made and editable after.
    var transcriptText: String?
    var createdAt: Date

    var position: TimeInterval { TimeInterval(positionMs) / 1000 }

    var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func tagString(_ tags: [String]) -> String? {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }
}
