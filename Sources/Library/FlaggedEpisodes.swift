import Foundation

/// Which episodes the library can't say enough about yet.
///
/// A synced library fills itself, and what it fills in depends entirely on what the files
/// happened to carry: a folder of untagged mp3s lands as a hundred episodes titled after
/// their own filenames, belonging to nobody, in no collection, with nothing said in them
/// searchable. Each one is findable on its own page, and invisible as a group — there is
/// no screen that answers "what still needs a look?".
///
/// This is that question, as plain checks. It marks; it doesn't mend — every reason
/// here already has a way to put it right by hand, and the one-tap version is not built
/// yet.
enum FlaggedEpisodes {
    enum Reason: String, CaseIterable, Identifiable, Sendable {
        /// Nothing transcribed. The one that costs the most elsewhere: search, summaries,
        /// terms and every AI suggestion read the transcript first.
        case noTranscript
        /// No speaker and/or no collection — either way, it can only be reached by
        /// searching for it.
        case unplaced
        /// Titled after its own file, which is what happens when no tag, no AI pass and
        /// nobody has given it a name.
        case filenameTitle
        /// Every copy of the audio is gone. The row stays until someone deletes it, or the
        /// same recording turns up in a bucket again.
        case noAudio

        var id: String { rawValue }
    }

    /// How many episodes are flagged, and what for. `total` counts episodes, not reasons:
    /// one untagged file is usually several of these at once, and adding the rows up
    /// would say the library is in four times the state it's in.
    struct Summary: Equatable, Sendable {
        var total = 0
        var counts: [Reason: Int] = [:]

        var isEmpty: Bool { total == 0 }
        func count(_ reason: Reason) -> Int { counts[reason] ?? 0 }
    }

    static func label(_ reason: Reason) -> String {
        switch reason {
        case .noTranscript: return "Not transcribed"
        case .unplaced: return "No speaker or collection"
        case .filenameTitle: return "Titled after its file"
        case .noAudio: return "Audio missing"
        }
    }

    struct Item: Identifiable, Sendable {
        var track: Track
        var reasons: Set<Reason>
        var id: String { track.id }
    }

    static func reasons(for track: Track, hasTranscript: Bool) -> Set<Reason> {
        // Nothing else can be filled in for an episode with nothing left to play.
        if track.isLost { return [.noAudio] }
        var reasons: Set<Reason> = []
        if !hasTranscript { reasons.insert(.noTranscript) }
        if track.artistID == nil || track.albumID == nil { reasons.insert(.unplaced) }
        if isNamedAfterItsFile(track) { reasons.insert(.filenameTitle) }
        return reasons
    }

    static func summary(tracks: [Track], transcribed: Set<String>) -> Summary {
        var summary = Summary()
        for track in tracks {
            let reasons = reasons(for: track, hasTranscript: transcribed.contains(track.id))
            guard !reasons.isEmpty else { continue }
            summary.total += 1
            for reason in reasons { summary.counts[reason, default: 0] += 1 }
        }
        return summary
    }

    /// Titles the app never improved on. Counts the numbered form too — `DuplicateTitles`
    /// turns a run of identical filename titles into `ep-001 (1)`, `ep-001 (2)`, and those
    /// are no more informative than what they came from.
    private static func isNamedAfterItsFile(_ track: Track) -> Bool {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return true }
        let file = ((track.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return DuplicateTitles.base(of: title) == file || title == file
    }
}
