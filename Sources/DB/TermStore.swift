import Foundation
import GRDB

/// Terms and how often each episode says them. Writes replace an episode's whole set —
/// an analysis pass is the authority on what that episode mentions, so a re-run leaves no
/// stale rows behind — and reads come back ordered by count, which is the only order a
/// frequency list has.
struct TermStore {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    /// Replaces this episode's terms. Names are matched case-insensitively against what's
    /// already there, so the second episode to mention someone joins their row rather
    /// than starting a second one under a different capitalisation.
    func setTerms(_ mentions: [String: Int], forTrack trackID: String) throws {
        try dbQueue.write { db in
            try TrackTerm.filter(Column("trackID") == trackID).deleteAll(db)
            for (rawName, count) in mentions {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, count > 0 else { continue }
                let existing = try Term
                    .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                    .fetchOne(db)
                let term = try existing ?? {
                    let term = Term(id: UUID().uuidString, name: name)
                    try term.insert(db)
                    return term
                }()
                try TrackTerm(trackID: trackID, termID: term.id, mentions: count).save(db)
            }
            // Nothing points at them any more, and an empty bar is still a bar.
            try db.execute(sql: """
                DELETE FROM terms WHERE id NOT IN (SELECT termID FROM trackTerms)
                """)
        }
        ChangeLog.record("terms", key: trackID, new: ["count": mentions.count], in: dbQueue)
    }

    /// One term added by hand. The count still isn't typed — it's counted in the
    /// transcript by the caller — because a number someone entered is the one number on
    /// this page that couldn't be checked.
    @discardableResult
    func add(name rawName: String, mentions: Int, forTrack trackID: String) throws -> Term? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return try dbQueue.write { db in
            let existing = try Term
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db)
            let term = try existing ?? {
                let term = Term(id: UUID().uuidString, name: name)
                try term.insert(db)
                return term
            }()
            try TrackTerm(trackID: trackID, termID: term.id, mentions: max(mentions, 1)).save(db)
            return term
        }
    }

    /// Takes a term off one episode. It stays on every other episode that mentions it —
    /// and goes entirely once no episode does, so a chart can't grow a bar of zero.
    func remove(termID: String, fromTrack trackID: String) throws {
        try dbQueue.write { db in
            try TrackTerm
                .filter(Column("trackID") == trackID && Column("termID") == termID)
                .deleteAll(db)
            try db.execute(sql: "DELETE FROM terms WHERE id NOT IN (SELECT termID FROM trackTerms)")
        }
    }

    /// Corrects one episode's count for one term. The term page recounts what it reads
    /// when it opens an episode, and a stored count that disagrees with the transcript is
    /// simply wrong — an older, worse count shouldn't outlive the evidence against it.
    func setMentions(_ mentions: Int, forTrack trackID: String, termID: String) throws {
        try dbQueue.write { db in
            try TrackTerm(trackID: trackID, termID: termID, mentions: max(mentions, 1)).save(db)
        }
    }

    /// Recounts every term this episode already carries against the transcript as it
    /// stands now, and says whether anything moved.
    ///
    /// **A count is a claim about a transcript, and transcripts grow.** The counting
    /// happens once, during the analysis pass, against however much had been transcribed
    /// by then — which for an episode analysed while it was still being transcribed is
    /// almost none of it. Every number downstream is a sum of these, so one stale row
    /// quietly wrongs the episode list, the album's terms and the library chart at the
    /// same time. Re-running the AI pass would fix it and cost a call; the transcript is
    /// right there and costs a scan.
    ///
    /// Terms are not added or removed here. What this episode is *about* is the model's
    /// answer and stays its answer — this only corrects the arithmetic underneath it, so
    /// a term it found but the recording paraphrases still holds its floor of one.
    @discardableResult
    func recount(forTrack trackID: String, in spoken: String) throws -> Bool {
        guard !spoken.isEmpty else { return false }
        return try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT terms.id AS termID, terms.name AS name, trackTerms.mentions AS mentions
                FROM trackTerms JOIN terms ON terms.id = trackTerms.termID
                WHERE trackTerms.trackID = ?
                """, arguments: [trackID])
            var changed = false
            for row in rows {
                let termID: String = row["termID"]
                let name: String = row["name"]
                let stored: Int = row["mentions"] ?? 0
                let said = max(1, EpisodeSummarizer.occurrences(of: name, in: spoken))
                guard said != stored else { continue }
                try TrackTerm(trackID: trackID, termID: termID, mentions: said).save(db)
                changed = true
            }
            return changed
        }
    }

    func terms(forTrack trackID: String) throws -> [TermCount] {
        try counts(sql: """
            SELECT terms.id, terms.name, SUM(trackTerms.mentions) AS mentions, COUNT(*) AS episodes
            FROM trackTerms JOIN terms ON terms.id = trackTerms.termID
            WHERE trackTerms.trackID = ?
            GROUP BY terms.id
            ORDER BY mentions DESC, terms.name
            """, arguments: [trackID])
    }

    /// Summed across the album's episodes — what the collection as a whole keeps coming
    /// back to, which is a different list from any one episode's.
    func terms(forAlbum albumID: String) throws -> [TermCount] {
        try counts(sql: """
            SELECT terms.id, terms.name, SUM(trackTerms.mentions) AS mentions,
                   COUNT(DISTINCT trackTerms.trackID) AS episodes
            FROM trackTerms
            JOIN terms ON terms.id = trackTerms.termID
            JOIN tracks ON tracks.id = trackTerms.trackID
            WHERE tracks.albumID = ?
            GROUP BY terms.id
            ORDER BY mentions DESC, terms.name
            """, arguments: [albumID])
    }

    /// The whole library, biggest first — what Home's chart draws.
    func topTerms(limit: Int = 40) throws -> [TermCount] {
        try counts(sql: """
            SELECT terms.id, terms.name, SUM(trackTerms.mentions) AS mentions,
                   COUNT(DISTINCT trackTerms.trackID) AS episodes
            FROM trackTerms JOIN terms ON terms.id = trackTerms.termID
            GROUP BY terms.id
            ORDER BY mentions DESC, terms.name
            LIMIT ?
            """, arguments: [limit])
    }

    /// Where a term is said, most-mentioning episode first — the term page's whole list.
    func episodes(forTerm termID: String) throws -> [(track: Track, mentions: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tracks.*, trackTerms.mentions AS termMentions
                FROM trackTerms JOIN tracks ON tracks.id = trackTerms.trackID
                WHERE trackTerms.termID = ?
                ORDER BY termMentions DESC, tracks.title
                """, arguments: [termID])
            return try rows.map { (try Track(row: $0), $0["termMentions"] ?? 0) }
        }
    }

    func find(id: String) throws -> Term? {
        try dbQueue.read { db in try Term.fetchOne(db, key: id) }
    }

    private func counts(sql: String, arguments: StatementArguments) throws -> [TermCount] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                TermCount(
                    term: Term(id: row["id"], name: row["name"]),
                    mentions: row["mentions"] ?? 0,
                    episodes: row["episodes"] ?? 1
                )
            }
        }
    }
}
