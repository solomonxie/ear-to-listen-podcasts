import Foundation

/// Keeps the app's own data — playlists, speaker and episode edits, the images they
/// reference, and transcripts — copied somewhere that outlives this install, so a
/// reinstall or a new phone doesn't start from nothing and nobody has to remember to
/// press Backup.
///
/// Two destinations, each its own switch: the listener's iCloud Drive (nothing to set
/// up, so it's the default one to offer) and the connected S3 bucket. Both are one-way
/// backup, not multi-device merge. Episode audio never goes up — it came out of that
/// bucket in the first place, and `SyncEngine` finds it again by itself.
///
/// Foreground-only, like `SyncScheduler` — there's no background-refresh entitlement. A
/// run ships the whole archive, so it only happens when something actually changed, and
/// at most once per `minimumInterval`.
@MainActor
final class AutoBackup: ObservableObject {
    static let shared = AutoBackup()

    private static let bucketEnabledKey = "backup.auto"
    private static let bucketLastKey = "backup.auto.lastAt"
    private static let cloudDriveEnabledKey = "backup.icloud"
    private static let cloudDriveLastKey = "backup.icloud.lastAt"
    private static let pollInterval: Duration = .seconds(60)
    private static let minimumInterval: TimeInterval = 15 * 60

    @Published var isEnabled: Bool {
        didSet { persist(isEnabled, forKey: Self.bucketEnabledKey, changedFrom: oldValue) }
    }

    /// Flipping it on backs up right away rather than waiting for the next edit, which
    /// could be days off — so "did that work?" is answered by the row itself.
    @Published var isCloudDriveEnabled: Bool {
        didSet {
            persist(isCloudDriveEnabled, forKey: Self.cloudDriveEnabledKey, changedFrom: oldValue)
            guard isCloudDriveEnabled, isCloudDriveEnabled != oldValue else { return }
            Task { await backUp(toBucket: false, toCloudDrive: true) }
        }
    }

    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCloudDriveBackupAt: Date?
    @Published private(set) var cloudDriveError: String?
    @Published private(set) var cloudDriveStatus: CloudDriveStatus = .notReady

    private var loopTask: Task<Void, Never>?
    private var changeObserver: (any NSObjectProtocol)?
    private var hasUnsavedChanges = false

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.bucketEnabledKey)
        isCloudDriveEnabled = defaults.bool(forKey: Self.cloudDriveEnabledKey)
        lastBackupAt = defaults.object(forKey: Self.bucketLastKey) as? Date
        lastCloudDriveBackupAt = defaults.object(forKey: Self.cloudDriveLastKey) as? Date
    }

    /// Called when a remote source is connected. An explicit "off" is left alone —
    /// switching it back on behind someone's back would make the toggle a lie.
    func enableForNewRemote() {
        guard UserDefaults.standard.object(forKey: Self.bucketEnabledKey) == nil else { return }
        isEnabled = true
    }

    /// The data came back out of iCloud after a reinstall, so that's plainly where it
    /// belongs — unless this install has already been told otherwise.
    func enableCloudDriveAfterRestore() {
        guard UserDefaults.standard.object(forKey: Self.cloudDriveEnabledKey) == nil else { return }
        isCloudDriveEnabled = true
    }

    /// Something worth keeping changed. Cheap on purpose: it only sets a flag, and the
    /// loop decides whether that's worth an upload yet.
    func markChanged() {
        hasUnsavedChanges = true
    }

    /// Called on every foreground, because the fix for a blocked iCloud row happens in
    /// the Settings app — the listener leaves, changes it, and comes back to a row that
    /// has to agree with what they just did.
    func start() {
        Task { cloudDriveStatus = await CloudDrive.status() }
        guard isEnabled || isCloudDriveEnabled, loopTask == nil else { return }
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

    func backUpNow() async {
        await backUp(toBucket: isEnabled, toCloudDrive: isCloudDriveEnabled)
    }

    private func persist(_ value: Bool, forKey key: String, changedFrom oldValue: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        guard value != oldValue else { return }
        value ? start() : stopIfIdle()
    }

    private func stopIfIdle() {
        guard !isEnabled, !isCloudDriveEnabled else { return }
        stop()
    }

    private func backUpIfDue() async {
        guard hasUnsavedChanges, !isBackingUp else { return }
        await backUp(
            toBucket: isEnabled && isDue(lastBackupAt),
            toCloudDrive: isCloudDriveEnabled && isDue(lastCloudDriveBackupAt)
        )
    }

    private func isDue(_ lastAt: Date?) -> Bool {
        guard let lastAt else { return true }
        return Date().timeIntervalSince(lastAt) >= Self.minimumInterval
    }

    private func backUp(toBucket: Bool, toCloudDrive: Bool) async {
        guard !isBackingUp, toBucket || toCloudDrive else { return }
        isBackingUp = true
        defer { isBackingUp = false }

        let service = BackupService()
        let archive: Data
        do {
            archive = try service.currentArchive()
        } catch {
            if toBucket { lastError = error.localizedDescription }
            if toCloudDrive { cloudDriveError = error.localizedDescription }
            return
        }

        var stillUnsaved = false
        if toBucket {
            do {
                try await service.upload(archive)
                lastBackupAt = Date()
                UserDefaults.standard.set(lastBackupAt, forKey: Self.bucketLastKey)
                lastError = nil
            } catch BackupError.noActiveRemoteProvider {
                // No bucket connected, or it was just switched off. Nothing to say about
                // it — this runs on a timer, not because anyone asked for it right now.
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                stillUnsaved = true
            }
        }
        if toCloudDrive {
            do {
                try await CloudDrive.write(archive)
                lastCloudDriveBackupAt = Date()
                UserDefaults.standard.set(lastCloudDriveBackupAt, forKey: Self.cloudDriveLastKey)
                cloudDriveError = nil
            } catch is CloudDriveError {
                // Signed out of iCloud is not a sync failure: the row already says so,
                // and a timer-driven run has nothing to add.
                cloudDriveStatus = await CloudDrive.status()
                cloudDriveError = nil
            } catch {
                cloudDriveError = error.localizedDescription
                stillUnsaved = true
            }
        }
        // Stays set if a destination that's switched on didn't take part in this run —
        // one that wasn't due yet still hasn't got this change.
        hasUnsavedChanges = stillUnsaved
            || (isEnabled && !toBucket)
            || (isCloudDriveEnabled && !toCloudDrive)
    }
}
