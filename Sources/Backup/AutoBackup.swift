import Foundation

/// Keeps the connected bucket's copy of the app's own data current on its own — playlists,
/// speaker and episode edits, the images they reference, and transcripts — so a reinstall
/// or a second device doesn't start from nothing and nobody has to remember to press
/// Backup.
///
/// Switched on when an S3 connection is added: handing the app a bucket is already saying
/// where this belongs. Episode audio never goes up — it came out of that bucket in the
/// first place, and `SyncEngine` finds it again by itself.
///
/// Foreground-only, like `SyncScheduler` — there's no background-refresh entitlement. A
/// run uploads the whole snapshot, so it only happens when something actually changed, and
/// at most once per `minimumInterval`.
@MainActor
final class AutoBackup: ObservableObject {
    static let shared = AutoBackup()

    private static let enabledKey = "backup.auto"
    private static let lastBackupKey = "backup.auto.lastAt"
    private static let pollInterval: Duration = .seconds(60)
    private static let minimumInterval: TimeInterval = 15 * 60

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastError: String?

    private var loopTask: Task<Void, Never>?
    private var changeObserver: (any NSObjectProtocol)?
    private var hasUnsavedChanges = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        lastBackupAt = UserDefaults.standard.object(forKey: Self.lastBackupKey) as? Date
    }

    /// Called when a remote source is connected. An explicit "off" is left alone —
    /// switching it back on behind someone's back would make the toggle a lie.
    func enableForNewRemote() {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) == nil else { return }
        isEnabled = true
    }

    /// Something worth keeping changed. Cheap on purpose: it only sets a flag, and the
    /// loop decides whether that's worth an upload yet.
    func markChanged() {
        hasUnsavedChanges = true
    }

    func start() {
        guard isEnabled, loopTask == nil else { return }
        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .libraryDidChange, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AutoBackup.shared.markChanged() }
            }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backUpIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func backUpIfDue() async {
        guard isEnabled, hasUnsavedChanges, !isBackingUp else { return }
        if let lastBackupAt, Date().timeIntervalSince(lastBackupAt) < Self.minimumInterval { return }
        await backUpNow()
    }

    func backUpNow() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            try await BackupService().backupToRemote()
            hasUnsavedChanges = false
            lastBackupAt = Date()
            UserDefaults.standard.set(lastBackupAt, forKey: Self.lastBackupKey)
            lastError = nil
        } catch BackupError.noActiveRemoteProvider {
            // No bucket connected, or it was just switched off. Nothing to say about it —
            // this runs on a timer, not because anyone asked for it right now.
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
