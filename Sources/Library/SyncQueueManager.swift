import Foundation

/// Runs enqueued per-file sync jobs with bounded concurrency. Manual "sync this folder" and
/// per-file work all flow through here rather than blocking synchronously, so progress is
/// visible and can be paused or cleared from `SyncQueueView`.
@MainActor
final class SyncQueueManager: ObservableObject {
    static let shared = SyncQueueManager()

    @Published private(set) var jobs: [SyncJob] = []
    @Published private(set) var providerLabels: [String: String] = [:]
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: Self.pausedKey) }
    }
    @Published var concurrency: Int {
        didSet { UserDefaults.standard.set(concurrency, forKey: Self.concurrencyKey) }
    }

    private static let pausedKey = "syncQueue.isPaused"
    private static let concurrencyKey = "syncQueue.concurrency"

    private let jobStore = SyncJobStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let syncEngine = SyncEngine()
    private var isDraining = false

    private init() {
        isPaused = UserDefaults.standard.bool(forKey: Self.pausedKey)
        let storedConcurrency = UserDefaults.standard.integer(forKey: Self.concurrencyKey)
        concurrency = storedConcurrency > 0 ? storedConcurrency : 2
        refresh()
    }

    func refresh() {
        jobs = (try? jobStore.all()) ?? []
        if let records = try? providerStore.all() {
            providerLabels = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.label) })
        }
    }

    /// Lists the whole connection recursively and enqueues every not-yet-imported audio
    /// file — run right after adding a source, so it fills in via the queue (visible
    /// per-file progress, retryable) instead of one opaque background sync.
    func enqueueConnection(providerID: String) async {
        guard
            let record = try? providerStore.all().first(where: { $0.id == providerID }),
            let provider = try? ProviderManager.shared.provider(for: record),
            let files = try? await provider.listFiles(inFolder: nil)
        else { return }

        for file in files where audioExtensions.contains((file.path as NSString).pathExtension.lowercased()) {
            guard (try? trackStore.find(providerID: providerID, filePath: file.path)) == nil else { continue }
            _ = try? jobStore.enqueue(providerID: providerID, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes)
        }
        refresh()
        startDraining()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { startDraining() }
    }

    func clearQueue() {
        try? jobStore.clearQueue()
        refresh()
    }

    /// Removes only completed jobs; pending/running ones stay in the list.
    func clearSynced() {
        try? jobStore.clearSynced()
        refresh()
    }

    /// Re-queues a failed job and wakes the drain loop back up.
    func retry(_ job: SyncJob) {
        try? jobStore.retry(id: job.id)
        refresh()
        startDraining()
    }

    private func startDraining() {
        guard !isDraining, !isPaused else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        defer { isDraining = false; refresh() }
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
        do {
            guard let record = try providerStore.all().first(where: { $0.id == job.providerID }) else {
                try? jobStore.markFailed(id: job.id, error: "Provider not found.")
                return
            }
            let provider = try ProviderManager.shared.provider(for: record)
            let file = CloudFile(id: job.filePath, name: job.displayName, path: job.filePath, sizeBytes: job.sizeBytes, mimeType: nil, modifiedAt: nil)
            try await syncEngine.importFileIfNeeded(file, providerRecord: record, provider: provider)
            try? jobStore.markDone(id: job.id)
        } catch {
            try? jobStore.markFailed(id: job.id, error: error.localizedDescription)
        }
        refresh()
    }
}
