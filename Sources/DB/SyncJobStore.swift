import Foundation
import GRDB

struct SyncJobStore {
    let dbQueue: DatabaseQueue

    @discardableResult
    func enqueue(providerID: String, filePath: String, displayName: String, sizeBytes: Int64?) throws -> SyncJob {
        let job = SyncJob(
            id: UUID().uuidString, providerID: providerID, filePath: filePath, displayName: displayName,
            sizeBytes: sizeBytes, status: .pending, errorMessage: nil, createdAt: Date(), updatedAt: Date()
        )
        try dbQueue.write { db in try job.save(db) }
        return job
    }

    func all() throws -> [SyncJob] {
        try dbQueue.read { db in try SyncJob.order(Column("createdAt")).fetchAll(db) }
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
