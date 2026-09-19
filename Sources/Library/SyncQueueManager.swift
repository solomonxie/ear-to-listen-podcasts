import Foundation

/// Runs enqueued per-file sync jobs with bounded concurrency. Manual "sync this folder" and
/// per-file work all flow through here rather than blocking synchronously, so progress is
/// visible and can be paused or cleared from `SyncQueueView`.
@MainActor
final class SyncQueueManager: ObservableObject {
    static let shared = SyncQueueManager()

    /// Only the visible page — use `totalCount`/`activeCount`/`activeProviderIDs` for
    /// anything counting the whole queue, since those aren't capped by pagination.
    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var activeCount = 0
    @Published private(set) var activeProviderIDs: Set<String> = []
    @Published private(set) var providerLabels: [String: String] = [:]
    /// Mirrors `SyncQueuePolicy.isPaused` for SwiftUI's benefit — the policy itself is
    /// what background sync passes read, since they can't touch this main-actor object.
    @Published var isPaused: Bool {
        didSet { SyncQueuePolicy.isPaused = isPaused }
    }
    /// Why the queue stopped taking work — full, or paused mid-enqueue. Shown on the queue
    /// screen, since a connection that silently stops half-listed reads like a bug.
    @Published private(set) var notice: String?
    @Published var concurrency: Int {
        didSet { UserDefaults.standard.set(concurrency, forKey: Self.concurrencyKey) }
    }

    private static let concurrencyKey = "syncQueue.concurrency"
    private static let pageSize = 100

    /// Grows only via `loadMore` — deliberately not reset by `refresh()`, which runs on
    /// every single job transition and would otherwise keep collapsing the list back to
    /// one page while the user is reading it.
    private var visibleLimit = pageSize

    var hasMore: Bool { totalCount > jobs.count }

    var isFull: Bool { activeCount >= SyncQueuePolicy.capacity }
    var capacity: Int { SyncQueuePolicy.capacity }

    private let jobStore = SyncJobStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let syncEngine = SyncEngine()
    private var isDraining = false

    /// Connections whose last listing pass hit the ceiling before it reached the end of
    /// the bucket. The drain loop comes back to them once it has made room, so a bucket
    /// of thousands finishes on its own instead of needing a Sync Now per hundred files.
    private var pendingTopUp: Set<String> = []

    private init() {
        isPaused = SyncQueuePolicy.isPaused
        let storedConcurrency = UserDefaults.standard.integer(forKey: Self.concurrencyKey)
        concurrency = storedConcurrency > 0 ? storedConcurrency : 2
        // Reclaim anything a previous launch was mid-way through, then pick the queue back
        // up. This finishes work the user already asked for (adding a connection queues its
        // files); it never goes out and re-lists anything, so a "Manual" connection stays
        // manual.
        try? jobStore.requeueOrphanedRunning()
        refresh()
        startDraining()
        NotificationCenter.default.addObserver(forName: .syncQueueDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                // Anything that queues work posts this, so it's also the wake-up: whoever
                // listed doesn't have to know whether the loop is running.
                self?.startDraining()
            }
        }
    }

    func refresh() {
        jobs = (try? jobStore.page(limit: visibleLimit)) ?? []
        let counts = (try? jobStore.counts()) ?? SyncJobStore.Counts(total: 0, active: 0)
        totalCount = counts.total
        activeCount = counts.active
        activeProviderIDs = (try? jobStore.activeProviderIDs()) ?? []
        // A "queue full" notice is only true while it is: once the drain loop has made
        // room, it's just a stale warning.
        if !isFull, !isPaused { notice = nil }
        if let records = try? providerStore.all() {
            providerLabels = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.label) })
        }
    }

    func loadMore() {
        visibleLimit += Self.pageSize
        refresh()
    }

    /// Lists a connection and queues everything that needs fetching, then wakes the drain
    /// loop. Every way into a sync goes through here — adding a source, "Sync Now", the
    /// background schedule, a local folder import — so there is one enqueue path, one
    /// place that remembers a bucket still has more to give, and one thing that starts
    /// the work.
    @discardableResult
    func sync(providerRecord record: ProviderRecord) async throws -> SyncResult {
        let result = try await syncEngine.sync(providerRecord: record)
        if result.stoppedAtQueueLimit {
            pendingTopUp.insert(record.id)
        } else {
            pendingTopUp.remove(record.id)
        }
        refresh()
        startDraining()
        return result
    }

    /// Run right after adding a source, so it fills in via the queue (visible per-file
    /// progress, retryable) instead of one opaque background sync.
    func enqueueConnection(providerID: String) async {
        guard let record = try? providerStore.all().first(where: { $0.id == providerID }) else { return }
        do {
            let result = try await sync(providerRecord: record)
            notice = result.stoppedAtQueueLimit
                ? SyncQueuePolicy.FullError().localizedDescription + " \(result.queued) queued so far."
                : nil
        } catch SyncEngineError.queuePaused {
            notice = "Queue paused — nothing was added. Resume to list this connection."
        } catch {
            notice = error.localizedDescription
        }
        refresh()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused {
            notice = nil
            startDraining()
        }
    }

    func clearQueue() {
        notice = nil
        try? jobStore.clearQueue()
        visibleLimit = Self.pageSize
        refresh()
    }

    /// Removes only completed jobs; pending/running ones stay in the list.
    func clearSynced() {
        try? jobStore.clearSynced()
        visibleLimit = Self.pageSize
        refresh()
    }

    /// Re-queues a failed job and wakes the drain loop back up.
    func retry(_ job: SyncJob) {
        try? jobStore.retry(id: job.id)
        refresh()
        startDraining()
    }

    func startDraining() {
        guard !isDraining, !isPaused else { return }
        isDraining = true
        Task { await drain() }
    }

    /// Works the queue empty, tops it back up from any connection that had more than would
    /// fit, and repeats until the buckets are done or the queue is paused.
    private func drain() async {
        defer { isDraining = false; refresh() }
        var didWork = false
        while !isPaused {
            // Re-checked rather than run once: `startDraining` is a no-op while this loop
            // is alive, so anything queued while the task group was winding down would
            // otherwise sit untouched until the user next tapped something.
            while !isPaused, (try? jobStore.hasPending()) == true {
                await drainPass()
                didWork = true
            }
            guard await topUp() else { break }
        }
        if didWork {
            // Once the batch has settled, not per file: numbering needs to see all the
            // siblings, and an episode imported halfway through a folder has none yet.
            let renamed = (try? trackStore.numberDuplicateTitles()) ?? 0
            if renamed > 0 { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
            await reapplyPendingRestore()
        }
    }

    /// Re-lists the connections that stopped at the ceiling. A pass that queues nothing is
    /// a connection that's finished (or can't be read), so it's dropped — that's what ends
    /// the loop rather than letting a bucket of permanently-failing files cycle forever.
    private func topUp() async -> Bool {
        guard !isPaused, !pendingTopUp.isEmpty else { return false }
        var queuedAnything = false
        for providerID in pendingTopUp {
            guard !isPaused else { break }
            guard
                let record = try? providerStore.all().first(where: { $0.id == providerID }),
                let result = try? await syncEngine.sync(providerRecord: record),
                result.queued > 0
            else {
                pendingTopUp.remove(providerID)
                continue
            }
            if !result.stoppedAtQueueLimit { pendingTopUp.remove(providerID) }
            queuedAnything = true
        }
        refresh()
        return queuedAnything
    }

    /// A restore that arrived before these files did has been waiting for them: its
    /// playlist order, hand edits and transcripts can only attach to tracks that exist,
    /// and an empty queue is the first moment that's true. Off the main actor — a
    /// multi-megabyte archive unpacked on it is a visible stall, and nothing on screen is
    /// waiting for it.
    private func reapplyPendingRestore() async {
        let dbQueue = DatabaseManager.shared.dbQueue
        await Task.detached { PendingRestore.reapplyAfterSync(dbQueue: dbQueue) }.value
        refresh()
    }

    private func drainPass() async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            // `dequeueNextPending` claims (marks `.running`) the job in the same transaction
            // it's fetched in, so this loop can't hand the same pending job to two tasks.
            while !isPaused, running < concurrency, let job = try? jobStore.dequeueNextPending() {
                running += 1
                refresh()
                group.addTask { await self.process(job) }
                if running >= concurrency {
                    await group.next()
                    running -= 1
                }
            }
            await group.waitForAll()
        }
    }

    private func process(_ job: SyncJob) async {
        guard let record = try? providerStore.all().first(where: { $0.id == job.providerID }) else {
            try? jobStore.markFailed(id: job.id, error: "Provider not found.")
            refresh()
            return
        }
        await syncEngine.perform(job, providerRecord: record)
        refresh()
    }
}
