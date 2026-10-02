import Foundation
import UIKit

/// Keeps the app's own data — playlists, speaker and episode edits, the images they
/// reference, and transcripts — copied somewhere that outlives this install, so a
/// reinstall or a new phone doesn't start from nothing and nobody has to remember to
/// press Backup.
///
/// Two destinations, each its own switch: the listener's iCloud Drive (nothing to set
/// up, so it's the default one to offer) and the connected bucket. Both are one-way
/// backup, not multi-device merge. Episode audio never goes up — it came out of that
/// bucket in the first place, and `SyncEngine` finds it again by itself.
///
/// **Driven by changes, not by the clock or the app's lifecycle.** A write to anything a
/// backup carries schedules one for when edits go quiet (`quietPeriod`), and leaving the
/// app sends out whatever is still owed. Nothing runs at launch and nothing polls. Each
/// destination — this phone (`LocalBackups`), iCloud Drive, the bucket — still takes a
/// whole archive at most once a day and only if the change log moved since its last
/// copy, and the archive is built once, off the main thread, for all three.
/// The mark is written down only
/// after the upload succeeds: record it before, and a failed upload is remembered as done,
/// so the next day's gate sees nothing new and skips — indefinitely.
///
/// Once a day rather than every few minutes because the gap is already covered: `ChangeLog`
/// and the tier-1 copies in `LocalBackups` hold everything written since this morning, and
/// they're on the phone the moment they're wanted.
@MainActor
final class AutoBackup: ObservableObject {
    static let shared = AutoBackup()

    private static let bucketEnabledKey = "backup.auto"
    private static let bucketLastKey = "backup.auto.lastAt"
    private static let bucketMarkKey = "backup.auto.mark"
    private static let cloudDriveEnabledKey = "backup.icloud"
    private static let cloudDriveLastKey = "backup.icloud.lastAt"
    private static let cloudDriveMarkKey = "backup.icloud.mark"
    /// Long enough that typing a note or working through an album is one backup, not one
    /// per row.
    private static let quietPeriod: Duration = .seconds(60)

    @Published var isEnabled: Bool {
        didSet { persist(isEnabled, forKey: Self.bucketEnabledKey, changedFrom: oldValue) }
    }

    /// Flipping it on backs up right away rather than waiting for the next edit, which
    /// could be days off — so "did that work?" is answered by the row itself.
    @Published var isCloudDriveEnabled: Bool {
        didSet {
            persist(isCloudDriveEnabled, forKey: Self.cloudDriveEnabledKey, changedFrom: oldValue)
            guard isCloudDriveEnabled, isCloudDriveEnabled != oldValue else { return }
            Task { await backUp(toPhone: false, toBucket: false, toCloudDrive: true) }
        }
    }

    @Published private(set) var isBackingUp = false
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCloudDriveBackupAt: Date?
    @Published private(set) var cloudDriveError: String?
    @Published private(set) var cloudDriveStatus: CloudDriveStatus = .notReady

    private var scheduled: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.bucketEnabledKey)
        isCloudDriveEnabled = defaults.bool(forKey: Self.cloudDriveEnabledKey)
        lastBackupAt = defaults.object(forKey: Self.bucketLastKey) as? Date
        lastCloudDriveBackupAt = defaults.object(forKey: Self.cloudDriveLastKey) as? Date
        NotificationCenter.default.addObserver(forName: .backedUpDataDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backUpSoon() }
        }
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

    /// Lets go of everything read out of the defaults a reset just wiped. Without it this
    /// object outlives the erase still switched on, and its gate reads a missing mark as
    /// "never shipped one" — so a minute later the empty library goes up over the copies
    /// the reset made on the way out.
    ///
    /// The keys are removed again after the assignments, because assigning writes them
    /// back: an erased install has never answered "back this up?", and the next connection
    /// added should still be able to ask.
    func forgetSettings() {
        isEnabled = false
        isCloudDriveEnabled = false
        lastBackupAt = nil
        lastCloudDriveBackupAt = nil
        lastError = nil
        cloudDriveError = nil
        scheduled?.cancel()
        let defaults = UserDefaults.standard
        for key in [
            Self.bucketEnabledKey, Self.bucketLastKey, Self.bucketMarkKey,
            Self.cloudDriveEnabledKey, Self.cloudDriveLastKey, Self.cloudDriveMarkKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Called on every foreground, because the fix for a blocked iCloud row happens in
    /// the Settings app — the listener leaves, changes it, and comes back to a row that
    /// has to agree with what they just did.
    func refreshCloudDriveStatus() {
        Task { cloudDriveStatus = await CloudDrive.status() }
    }

    /// Restarted by every write, so a burst of them is one backup at its end.
    private func backUpSoon() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            await self?.backUpIfDue()
        }
    }

    /// With the time iOS gives an app that has just been put away.
    func backUpOnLeaving() {
        scheduled?.cancel()
        let assertion = BackgroundAssertion(name: "backup")
        Task {
            await backUpIfDue()
            assertion.end()
        }
    }

    func backUpNow() async {
        await backUp(toPhone: false, toBucket: isEnabled, toCloudDrive: isCloudDriveEnabled)
    }

    /// The recovery point written immediately before an irreversible local reset, under a
    /// name of its own so a later backup of the empty library can't replace it. No picker
    /// and nothing to confirm: a save sheet is one more thing to get wrong at the only
    /// moment the copy matters.
    ///
    /// It goes wherever there is somewhere to put it — a connected bucket and a ready
    /// iCloud Drive both take it whether or not the daily switch is on. Those two are the
    /// copies that matter here: the local one shares the sandbox this is about to empty,
    /// so it survives the reset but not deleting the app. A destination that fails is
    /// left out of the summary rather than stopping the reset, but the local copy has to
    /// land or there is no copy at all.
    @discardableResult
    func backUpBeforeDeletion() async throws -> String {
        let service = BackupService()
        let snapshot = try service.makeSnapshot()
        // Erasing a library that is already empty has nothing to preserve, and the copy
        // it would write is the most dangerous file this app can make: a pre-deletion
        // name outranks every dated archive on every destination, so an empty one hides
        // the real recovery copy for good.
        guard !snapshot.isEmpty else { return "Nothing to back up — this library is already empty." }
        let archive = try service.archive(snapshot)
        let name = BackupArchiveName.preDeletion()
        guard LocalBackups.writePreDeletion(archive, named: name) != nil else {
            throw CocoaError(.fileWriteUnknown)
        }

        var destinations = ["Files"]
        do {
            try await service.uploadPreDeletion(archive, named: name)
            destinations.append("the bucket")
        } catch BackupError.noActiveRemoteProvider {
            // Nothing connected to write to, which is not a failure of this run.
        } catch {
            lastError = error.localizedDescription
        }
        if await CloudDrive.status().isReady {
            do {
                try await CloudDrive.write(archive, named: name)
                destinations.append("iCloud Drive")
            } catch {
                cloudDriveError = error.localizedDescription
            }
        }
        return "Saved \(name) to \(destinations.formatted())."
    }

    private func persist(_ value: Bool, forKey key: String, changedFrom oldValue: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func backUpIfDue() async {
        guard !isBackingUp else { return }
        await backUp(
            toPhone: LocalBackups.isDue,
            toBucket: isEnabled && isDue(lastBackupAt, markKey: Self.bucketMarkKey),
            toCloudDrive: isCloudDriveEnabled && isDue(lastCloudDriveBackupAt, markKey: Self.cloudDriveMarkKey)
        )
    }

    /// Once a day, and only if something was written since the copy this destination
    /// already holds. Never having shipped one counts as changed — a library that predates
    /// the change log has plenty worth keeping and a mark of zero.
    private func isDue(_ lastAt: Date?, markKey: String) -> Bool {
        guard let shipped = UserDefaults.standard.object(forKey: markKey) as? Int else { return true }
        guard ChangeLog.mark != shipped else { return false }
        guard let lastAt else { return true }
        return !Calendar.current.isDateInToday(lastAt)
    }

    private func backUp(toPhone: Bool, toBucket: Bool, toCloudDrive: Bool) async {
        guard !isBackingUp, toPhone || toBucket || toCloudDrive, !AppMode.isDemo else { return }
        isBackingUp = true
        defer { isBackingUp = false }

        let mark = ChangeLog.mark
        let built = await Self.buildArchive()
        let archive: Data
        switch built {
        case .success(let data?):
            archive = data
        case .success(nil):
            // A library with nothing in it is a state to be recovered from, not one to
            // ship: today's key in the bucket is taken by it, and ten empty days prune
            // iCloud clean of every copy that still had the library in it.
            return
        case .failure(let error):
            if toBucket { lastError = error.localizedDescription }
            if toCloudDrive { cloudDriveError = error.localizedDescription }
            return
        }

        if toPhone {
            await Task.detached(priority: .utility) { LocalBackups.save(archive, mark: mark) }.value
        }
        if toBucket {
            do {
                try await BackupService().upload(archive)
                lastBackupAt = Date()
                UserDefaults.standard.set(lastBackupAt, forKey: Self.bucketLastKey)
                UserDefaults.standard.set(mark, forKey: Self.bucketMarkKey)
                lastError = nil
            } catch BackupError.noActiveRemoteProvider {
                // No bucket connected, or it was just switched off. Nothing to say about
                // it — this runs on a timer, not because anyone asked for it right now.
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        if toCloudDrive {
            do {
                try await CloudDrive.write(archive)
                lastCloudDriveBackupAt = Date()
                UserDefaults.standard.set(lastCloudDriveBackupAt, forKey: Self.cloudDriveLastKey)
                UserDefaults.standard.set(mark, forKey: Self.cloudDriveMarkKey)
                cloudDriveError = nil
            } catch is CloudDriveError {
                // Signed out of iCloud is not a sync failure: the row already says so,
                // and a timer-driven run has nothing to add.
                cloudDriveStatus = await CloudDrive.status()
                cloudDriveError = nil
            } catch {
                cloudDriveError = error.localizedDescription
            }
        }
    }

    /// Seconds of work on a big library, so never on the main thread. Nil for an empty one.
    private nonisolated static func buildArchive() async -> Result<Data?, Error> {
        await Task.detached(priority: .utility) {
            Result {
                let service = BackupService()
                let snapshot = try service.makeSnapshot()
                return snapshot.isEmpty ? nil : try service.archive(snapshot)
            }
        }.value
    }
}

@MainActor
private final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
