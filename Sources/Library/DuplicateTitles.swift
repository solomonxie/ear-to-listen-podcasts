import Foundation

/// Tells apart episodes in one collection that arrived with identical titles.
///
/// A folder of files sharing one embedded title tag is the normal case, not the odd one —
/// a hundred `2 徒 1-260 全` rows say nothing about which is which, and the only thing that
/// does is the filename. Numbering them in filename order gives every row a name that
/// means something and keeps the order the files are actually in.
///
/// ```
///   唯独恩典          →   唯独恩典 (1)     ep-001.mp3
///   唯独恩典              唯独恩典 (2)     ep-002.mp3
///   唯独恩典              唯独恩典 (3)     ep-010.mp3
/// ```
///
/// **It undoes itself — but only its own work.** Numbering is a statement about a
/// *collision*, so when the collision goes — the second source disconnected, the
/// duplicate deleted — the survivor goes back to its plain title: a library carrying
/// `(2)` with no `(1)` anywhere in it is a number answering a question nobody can still
/// see. What makes that safe is `Track.numberedFrom`, the title this pass renamed *from*.
/// An episode legitimately called `Encore (2)` has no such record and is never touched;
/// without the column the two are indistinguishable, and stripping by pattern alone would
/// be the app inventing a rename nobody asked for.
enum DuplicateTitles {
    /// A title this pass produced, so a second run recognises its own work rather than
    /// numbering the numbers. Built per call rather than held in a `static` — a `Regex`
    /// isn't `Sendable`, and this is cheap next to the database write it guards.
    private static var suffix: Regex<(Substring, Substring, Substring)> {
        /^(.*) \((\d+)\)$/
    }

    /// What one track's title should become, and what to remember about it.
    struct Renumbering: Equatable {
        var title: String
        /// The title the episode had before this pass first touched it, kept so the
        /// number can be taken off again. Nil when the number is being removed.
        var numberedFrom: String?
    }

    /// The new title for every track that needs one, keyed by track id. Tracks that
    /// already read correctly aren't in the result.
    ///
    /// Works off the *base* title, so an episode arriving later joins the existing run
    /// rather than sitting beside it as a bare `X`. Idempotence comes from only recording
    /// a change when there is one: a run that's already `X (1)`, `X (2)` re-derives to
    /// exactly those titles and reports nothing to do.
    static func renumbered(_ tracks: [Track]) -> [String: Renumbering] {
        var byBase: [String: [Track]] = [:]
        for track in tracks {
            byBase[base(of: track.title), default: []].append(track)
        }

        var renamed: [String: Renumbering] = [:]
        for (base, group) in byBase {
            // A title someone typed is an answer, not a collision to resolve — if any of
            // these was edited by hand, the whole run is left as it is.
            guard group.allSatisfy({ $0.metadataEditedAt == nil }) else { continue }
            // Nothing left to be ambiguous with. Only a number this pass put on comes
            // off — `numberedFrom` is the receipt, and a title that simply ends in "(2)"
            // never had one.
            guard group.count > 1 else {
                if let only = group.first, let original = only.numberedFrom, only.title != original {
                    renamed[only.id] = Renumbering(title: original, numberedFrom: nil)
                }
                continue
            }
            // The filename is the only thing that orders them, and it's the order they're
            // in on the storage the listener actually looks at.
            for (index, track) in group.sorted(by: { $0.filePath < $1.filePath }).enumerated() {
                let title = "\(base) (\(index + 1))"
                guard title != track.title else { continue }
                renamed[track.id] = Renumbering(
                    title: title, numberedFrom: track.numberedFrom ?? track.title
                )
            }
        }
        return renamed
    }

    /// `X (2)` → `X`, anything else unchanged.
    static func base(of title: String) -> String {
        guard let match = title.wholeMatch(of: suffix) else { return title }
        return String(match.1)
    }
}
