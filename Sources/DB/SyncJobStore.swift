import Foundation
import GRDB

struct SyncJobStore {
    let dbQueue: DatabaseQueue

    /// One unfinished job per file, and it's the newest request that survives. Adding a
    /// connection queues its whole listing, and a "Sync Now" over the same listing would
    /// otherwise queue every path a second time — two workers then work the same file at
    /// once, and for a write-back job that means uploading it twice. A still-pending
    /// duplicate is therefore replaced rather than kept: the later request carries the
    /// later size/hash, which is the one worth acting on. A job already *running* is left
    /// alone — it's doing the work now, and the newer request adds nothing to it.
    /// Finished/failed rows don't block a fresh one, so a re-sync still works.
    ///
    /// Throws `SyncQueuePolicy.FullError` once `capacity` files are already waiting. The
    /// count is taken inside the same transaction as the insert, so two callers queueing
    /// at once can't both see room for the last slot. A file already in flight is returned
    /// as-is and never counts against the ceiling — that's not an addition.
    @discardableResult
    func enqueue(
        providerID: String, filePath: String, displayName: String, sizeBytes: Int64?,
        contentHash: String? = nil, remoteModifiedAt: Date? = nil, transcriptPath: String? = nil,
        uploadBookmark: String? = nil, capacity: Int = SyncQueuePolicy.capacity
    ) throws -> SyncJob {
        try dbQueue.write { db in
            if let existing = try Self.unfinished(providerID: providerID, filePath: filePath).fetchOne(db) {
                guard existing.status == .pending else { return existing }
                try existing.delete(db)
            }
            guard try Self.unfinishedCount(db) < capacity else { throw SyncQueuePolicy.FullError() }
            let job = SyncJob(
                id: UUID().uuidString, providerID: providerID, filePath: filePath, displayName: displayName,
                sizeBytes: sizeBytes, contentHash: contentHash, remoteModifiedAt: remoteModifiedAt,
                transcriptPath: transcriptPath, uploadBookmark: uploadBookmark, status: .pending,
                stage: .queued, errorMessage: nil, createdAt: Date(), updatedAt: Date()
            )
            try job.save(db)
            return job
        }
    }

    /// Whether this file is already queued or being worked, so a listing pass can leave it
    /// alone. Without this, `enqueue` would delete and re-insert the pending row with a
    /// fresh `createdAt` — and `createdAt` is the queue order, so a "Sync Now" over a full
    /// queue would shuffle everything already waiting back to the end.
    func hasUnfinished(providerID: String, filePath: String) throws -> Bool {
        try dbQueue.read { db in
            try Self.unfinished(providerID: providerID, filePath: filePath).fetchCount(db) > 0
        }
    }

    /// Whether anything is still waiting to be claimed. The drain loop re-checks this
    /// before giving up, so files queued while it was winding down don't sit idle until
    /// the next thing the user taps. Deliberately pending-only: a row stranded `.running`
    /// would otherwise spin the loop forever against a queue with nothing claimable in it.
    func hasPending() throws -> Bool {
        try dbQueue.read { db in
            try SyncJob.filter(Column("status") == SyncJobStatus.pending.rawValue).fetchCount(db) > 0
        }
    }

    private static func unfinishedCount(_ db: Database) throws -> Int {
        try SyncJob
            .filter([SyncJobStatus.pending.rawValue, SyncJobStatus.running.rawValue].contains(Column("status")))
            .fetchCount(db)
    }

    private static func unfinished(providerID: String, filePath: String) -> QueryInterfaceRequest<SyncJob> {
        SyncJob
            .filter(Column("providerID") == providerID && Column("filePath") == filePath)
            .filter([SyncJobStatus.pending.rawValue, SyncJobStatus.running.rawValue].contains(Column("status")))
    }

    /// Done jobs sink to the bottom so pending/running/failed ones — the ones still worth
    /// looking at — stay on top. Within each group the useful order differs: not-yet-done
    /// jobs read in the order they were queued (which is also the order `dequeueNextPending`
    /// will work them, so the top row is genuinely next up), while finished ones read
    /// newest-first, since the interesting end of a completed pile is what just landed.
    ///
    /// `limit` keeps a bucket with thousands of queued files from loading in one go — see
    /// `SyncQueueManager.loadMore`. Counting is `counts()`, which never loads rows.
    func page(limit: Int) throws -> [SyncJob] {
        try dbQueue.read { db in
            try SyncJob
                .order(sql: """
                    status = 'done',
                    CASE WHEN status = 'done' THEN NULL ELSE createdAt END ASC,
                    CASE WHEN status = 'done' THEN updatedAt ELSE NULL END DESC
                    """)
                .limit(limit)
                .fetchAll(db)
        }
    }

    struct Counts {
        /// Everything in the queue, for deciding whether there's another page to load.
        var total: Int
        /// Pending + running — what "N pending" in the UI means.
        var active: Int
    }

    func counts() throws -> Counts {
        try dbQueue.read { db in
            let total = try SyncJob.fetchCount(db)
            let active = try SyncJob
                .filter([SyncJobStatus.pending.rawValue, SyncJobStatus.running.rawValue].contains(Column("status")))
                .fetchCount(db)
            return Counts(total: total, active: active)
        }
    }

    /// Which providers have unfinished work, so a connection's own screen can show it's
    /// syncing without holding every job row in memory.
    func activeProviderIDs() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT providerID FROM syncJobs WHERE status IN (?, ?)
                """, arguments: [SyncJobStatus.pending.rawValue, SyncJobStatus.running.rawValue]))
        }
    }

    /// Atomically claims the oldest pending job in one write transaction — fetching and
    /// flipping it to `.running` as a single step so two concurrent drain loops can't both
    /// read it while it's still `.pending` and each start processing the same file.
    func dequeueNextPending() throws -> SyncJob? {
        try dbQueue.write { db in
            guard var job = try SyncJob
                .filter(Column("status") == SyncJobStatus.pending.rawValue)
                .order(Column("createdAt"))
                .fetchOne(db)
            else { return nil }
            job.status = .running
            job.updatedAt = Date()
            try job.save(db)
            return job
        }
    }

    func markStage(id: String, _ stage: SyncJobStage) throws {
        try update(id: id) { $0.stage = stage }
    }

    /// A `.running` row can't outlive the process that was working it, so anything still
    /// marked running at launch was orphaned by a kill/crash mid-drain. Put those back in
    /// line — left alone they're worked by nobody, yet still count as active, which reads
    /// as a connection that's permanently "Syncing…".
    @discardableResult
    func requeueOrphanedRunning() throws -> Int {
        try dbQueue.write { db in
            try SyncJob
                .filter(Column("status") == SyncJobStatus.running.rawValue)
                .updateAll(db, Column("status").set(to: SyncJobStatus.pending.rawValue), Column("updatedAt").set(to: Date()))
        }
    }

    func markDone(id: String) throws {
        try update(id: id) { $0.status = .done }
    }

    func markFailed(id: String, error: String) throws {
        try update(id: id) { $0.status = .failed; $0.errorMessage = error }
    }

    /// Re-queues a failed job for another attempt.
    func retry(id: String) throws {
        try update(id: id) { $0.status = .pending; $0.stage = .queued; $0.errorMessage = nil }
    }

    private func update(id: String, _ mutate: (inout SyncJob) -> Void) throws {
        try dbQueue.write { db in
            guard var job = try SyncJob.fetchOne(db, key: id) else { return }
            mutate(&job)
            job.updatedAt = Date()
            try job.save(db)
        }
    }

    /// Drops every job regardless of status, including ones a worker is actively processing.
    func clearQueue() throws {
        try dbQueue.write { db in try SyncJob.deleteAll(db) }
    }

    /// Drops only completed jobs, leaving pending/running (still syncing) and failed
    /// (needs a retry decision) ones visible.
    func clearSynced() throws {
        try dbQueue.write { db in
            try SyncJob.filter(Column("status") == SyncJobStatus.done.rawValue).deleteAll(db)
        }
    }
}
