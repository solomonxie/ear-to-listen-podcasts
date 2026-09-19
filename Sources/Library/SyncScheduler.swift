import Foundation

/// Periodically syncs providers that are due, per their `syncFrequencyMinutes`, for as long
/// as the app is active. There's no background-refresh entitlement wired up, so this is
/// foreground-only — sync resumes on next launch/foreground if it missed a window.
@MainActor
final class SyncScheduler: ObservableObject {
    static let shared = SyncScheduler()

    private static let pollInterval: Duration = .seconds(60)

    @Published private(set) var isRunning = false

    private var loopTask: Task<Void, Never>?
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)

    private init() {}

    func start() {
        guard loopTask == nil else { return }
        isRunning = true
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncDueProviders()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    private func syncDueProviders() async {
        // Pausing the queue pauses the schedule with it — otherwise the one control that
        // says "stop syncing" wouldn't stop the syncing that happens on its own.
        guard !SyncQueuePolicy.isPaused else { return }
        guard let records = try? providerStore.active() else { return }
        let now = Date()
        for record in records {
            guard let minutes = record.syncFrequencyMinutes, minutes > 0 else { continue }
            let due = record.lastSyncedAt.map { now.timeIntervalSince($0) >= Double(minutes * 60) } ?? true
            guard due else { continue }
            _ = try? await SyncQueueManager.shared.sync(providerRecord: record)
        }
    }
}
