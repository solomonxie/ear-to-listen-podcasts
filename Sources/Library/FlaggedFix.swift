import Foundation
import GRDB

/// One way to put a flagged episode right. A fix applies to the items it fits and skips
/// the rest, so one choice can run over a mixed selection.
enum FlaggedFix: String, CaseIterable, Identifiable, Sendable {
    case tidyTitle, rename, assignPlace, neglect, deleteRecord, deleteWithFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tidyTitle: return "Tidy title"
        case .rename: return "Rename…"
        case .assignPlace: return "Set speaker & collection…"
        case .neglect: return "Neglect"
        case .deleteRecord: return "Delete record"
        case .deleteWithFile: return "Delete record and file"
        }
    }

    var symbol: String {
        switch self {
        case .tidyTitle: return "wand.and.stars"
        case .rename: return "pencil"
        case .assignPlace: return "person.crop.circle.badge.plus"
        case .neglect: return "eye.slash"
        case .deleteRecord, .deleteWithFile: return "trash"
        }
    }

    var isDestructive: Bool { self == .deleteRecord || self == .deleteWithFile }

    /// Only for one episode at a time: it needs its own answer.
    var isSingleOnly: Bool { self == .rename }

    func applies(to item: FlaggedEpisodes.Item) -> Bool {
        switch self {
        case .tidyTitle: return FlaggedFixer.tidiedTitle(of: item.track) != nil
        case .rename: return true
        case .assignPlace: return item.reasons.contains(.unplaced)
        case .neglect: return true
        case .deleteRecord: return item.track.isLost
        case .deleteWithFile: return !item.track.isLost
        }
    }

    /// The fixes that mend what a given flag says.
    static func suggested(for reason: FlaggedEpisodes.Reason) -> [FlaggedFix] {
        switch reason {
        case .noAudio: return [.deleteRecord, .neglect]
        case .filenameTitle: return [.tidyTitle, .rename, .neglect]
        case .unplaced: return [.assignPlace, .neglect]
        case .noTranscript: return [.neglect, .deleteWithFile]
        }
    }
}

struct FlaggedFixOutcome {
    var fixed = 0
    var skipped = 0
    var failures: [String] = []
}

struct FlaggedFixer {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) { self.dbQueue = dbQueue }

    /// What the file's own name says once the separators and a leading track number are
    /// gone. Nil when that is no better than the title already there.
    static func tidiedTitle(of track: Track) -> String? {
        let file = ((track.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = file.replacingOccurrences(of: "_", with: " ")
        if let range = name.range(of: #"^\d+[\s.\-]+"#, options: .regularExpression), range.upperBound < name.endIndex {
            name.removeSubrange(range)
        }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name != file, name != track.title else { return nil }
        return name
    }

    func apply(
        _ fix: FlaggedFix, to items: [FlaggedEpisodes.Item], title: String? = nil, speaker: String? = nil,
        collection: String? = nil
    ) async -> FlaggedFixOutcome {
        var outcome = FlaggedFixOutcome()
        let targets = items.filter { fix.applies(to: $0) }
        outcome.skipped = items.count - targets.count
        let trackStore = TrackStore(dbQueue: dbQueue)
        let library = LibraryStore(dbQueue: dbQueue)

        switch fix {
        case .neglect:
            do {
                try trackStore.setNeglected(ids: targets.map(\.id), neglected: true)
                outcome.fixed = targets.count
            } catch { outcome.failures.append(error.localizedDescription) }
        case .deleteRecord, .deleteWithFile:
            let result = await EpisodeRemoval(dbQueue: dbQueue).delete(trackIDs: targets.map(\.id))
            outcome.fixed = result.deleted
            outcome.failures = result.failures
        case .tidyTitle, .rename, .assignPlace:
            for item in targets {
                do {
                    var track = item.track
                    var artistName = try track.artistID.flatMap { try library.artist(id: $0)?.name }
                    var albumName = try track.albumID.flatMap { try library.album(id: $0)?.name }
                    switch fix {
                    case .tidyTitle: track.title = Self.tidiedTitle(of: track) ?? track.title
                    case .rename: track.title = title?.trimmingCharacters(in: .whitespaces) ?? track.title
                    default:
                        if let speaker, !speaker.isEmpty { artistName = speaker }
                        if let collection, !collection.isEmpty { albumName = collection }
                        let artist = try artistName.map { try library.upsertArtist(name: $0) }
                        let album = try albumName.map { try library.upsertAlbum(name: $0, artistID: artist?.id) }
                        track.artistID = artist?.id
                        track.albumID = album?.id
                    }
                    track.metadataEditedAt = Date()
                    try trackStore.saveEdit(track, artistName: artistName, albumName: albumName)
                    outcome.fixed += 1
                } catch { outcome.failures.append("\(item.track.title): \(error.localizedDescription)") }
            }
        }

        var detail = targets.prefix(3).map(\.track.title).joined(separator: ", ")
        if targets.count > 3 { detail += " and \(targets.count - 3) more" }
        if outcome.skipped > 0 { detail += " — \(outcome.skipped) skipped, didn't fit" }
        if !outcome.failures.isEmpty { detail += " — \(outcome.failures.count) failed" }
        if outcome.fixed > 0 || !outcome.failures.isEmpty {
            FixHistoryStore(dbQueue: dbQueue).record(action: fix.title.replacingOccurrences(of: "…", with: ""), count: outcome.fixed, detail: detail)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return outcome
    }
}
