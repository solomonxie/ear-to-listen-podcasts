import Foundation

/// Runs enqueued per-file sync jobs with bounded concurrency. Manual "sync this folder" and
/// per-file work all flow through here rather than blocking synchronously, so progress is
/// visible and can be paused or cleared from `SyncQueueView`.
@MainActor
final class SyncQueueManager: ObservableObject {
    static let shared = SyncQueueManager()

    @Published private(set) var jobs: [SyncJob] = []
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
    }

    /// Lists `folder` one level deep (non-recursive) and enqueues any files not yet imported.
    func enqueueFolder(providerID: String, folder: String?) async {
        guard
            let record = try? providerStore.all().first(where: { $0.id == providerID }),
            let provider = try? ProviderManager.shared.provider(for: record),
            let listing = try? await provider.listDirectory(atFolder: folder)
        else { return }

        for file in listing.files {
            guard (try? trackStore.find(providerID: providerID, filePath: file.path)) == nil else { continue }
            try? jobStore.enqueue(providerID: providerID, filePath: file.path, displayName: file.name, sizeBytes: file.sizeBytes)
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

    private func startDraining() {
        guard !isDraining, !isPaused else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        defer { isDraining = false; refresh() }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !isPaused, running < concurrency, let job = try? jobStore.nextPending() {
                running += 1
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
        try? jobStore.markRunning(id: job.id)
        refresh()
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
