import Foundation
import GRDB

/// Puts the listener's data back by itself after the app is deleted and reinstalled, or
/// set up on a new phone. There is no manual "restore from X" button anywhere; the only
/// hand-driven path is Import Library Data, from a file they picked.
///
/// No prompt: on first launch nobody has the context to answer "restore from backup?",
/// and getting the data back is the entire point of having taken it. It only ever runs
/// onto an untouched library, so there is nothing to overwrite and no way to end up with
/// two of everything.
///
/// iCloud is tried first and wins outright — it needs no setup, so it's there on the very
/// first launch, before any bucket could have been reconnected. The bucket is the second
/// chance, for anyone who keeps app data there instead, and it can only be taken once
/// they've added the connection back (its credentials went with the app).
enum FirstRunRestore {
    private static let didRestoreKey = "backup.icloud.didRestore"

    /// Say this install has had its restore, so an empty library stops being read as a
    /// fresh one. Removing all app data wipes the defaults this flag lives in, and the
    /// archive it writes on the way out is exactly what a first run would pull back down.
    static func markDone() {
        UserDefaults.standard.set(true, forKey: didRestoreKey)
    }

    static func runIfNeeded() async {
        guard shouldRun(ignoringProviders: 0) else { return }
        // "Not ready yet" — container still propagating, iCloud signed out, an unsigned
        // build — is not a failure and not something to report on a first launch. Leave
        // the flag alone and try again next time, while the library is still empty.
        guard await CloudDrive.status().isReady else { return }
        // The newest name isn't always the one to take: a wipe of an already-empty
        // library used to leave an archive holding nothing, sorting above every copy
        // that still had the library in it.
        guard let archive = try? await CloudDrive.latestBackup(acceptable: BackupService().holdsData) else { return }
        guard apply(archive) else { return }
        await MainActor.run { AutoBackup.shared.enableCloudDriveAfterRestore() }
    }

    /// The bucket that was just reconnected counts as the one provider a fresh library is
    /// allowed to have. Only if it's keeping app data — a bucket told not to back up isn't
    /// a restore source either.
    static func runAfterConnectingRemote() async {
        guard shouldRun(ignoringProviders: 1) else { return }
        guard await MainActor.run(body: { AutoBackup.shared.isEnabled }) else { return }
        guard let archive = try? await BackupService().downloadRemoteArchive() else { return }
        _ = apply(archive)
    }

    private static func shouldRun(ignoringProviders allowance: Int) -> Bool {
        guard !UserDefaults.standard.bool(forKey: didRestoreKey) else { return false }
        let dbQueue = DatabaseManager.shared.dbQueue
        let providers = (try? ProviderStore(dbQueue: dbQueue).all().count) ?? .max
        let playlists = (try? PlaylistStore(dbQueue: dbQueue).all().count) ?? .max
        let tracks = (try? TrackStore(dbQueue: dbQueue).all(includingLost: true).count) ?? .max
        return providers <= allowance && playlists == 0 && tracks == 0
    }

    private static func apply(_ archive: Data) -> Bool {
        let service = BackupService()
        guard let snapshot = try? service.unarchive(archive),
              (try? service.apply(snapshot)) != nil
        else { return false }

        // The episodes themselves aren't here yet, so the edits and transcripts pointing
        // at them can't land until a sync has fetched the files.
        PendingRestore.save(archive)
        UserDefaults.standard.set(true, forKey: didRestoreKey)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return true
    }
}
