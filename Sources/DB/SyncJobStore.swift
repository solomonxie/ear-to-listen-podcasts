import Foundation
import GRDB

struct SyncJobStore {
    let dbQueue: DatabaseQueue

    /// One unfinished job per file. Adding a connection queues its whole listing, and a
    /// "Sync Now" over the same listing would otherwise queue every path a second time —
    /// two workers then import the same file at once. Returns the job already in flight
    /// instead. Finished/failed rows don't block a fresh one, so a re-sync still works.
    @discardableResult
    func enqueue(
        providerID: String, filePath: String, displayName: String, sizeBytes: Int64?,
        contentHash: String? = nil, remoteModifiedAt: Date? = nil
    ) throws -> SyncJob {
        try dbQueue.write { db in
            if let existing = try Self.unfinished(providerID: providerID, filePath: filePath).fetchOne(db) {
                return existing
            }
            let job = SyncJob(
                id: UUID().uuidString, providerID: providerID, filePath: filePath, displayName: displayName,
                sizeBytes: sizeBytes, contentHash: contentHash, remoteModifiedAt: remoteModifiedAt,
                status: .pending, errorMessage: nil, createdAt: Date(), updatedAt: Date()
            )
            try job.save(db)
            return job
        }
    }

    /// Whether this file is already queued or being worked — lets `SyncEngine.sync` leave
    /// it to the drain loop rather than importing it inline at the same time.
    func hasUnfinished(providerID: String, filePath: String) throws -> Bool {
        try dbQueue.read { db in
            try Self.unfinished(providerID: providerID, filePath: filePath).fetchCount(db) > 0
        }
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

    /// Flips an already-enqueued job straight to `.running` — for a caller that's about to
    /// process it inline itself, rather than leaving it `.pending` for a drain loop to claim.
    func markRunning(id: String) throws {
        try update(id: id) { $0.status = .running }
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
        try update(id: id) { $0.status = .pending; $0.errorMessage = nil }
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
