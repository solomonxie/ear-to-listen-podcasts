import Foundation

/// The library snapshot the app keeps in the listener's own storage, in whichever cloud
/// they connected. Written through `upload`/`listFiles`/`download` only, so a new backend
/// gets backup and restore for free the moment it can list and write.
extension CloudProvider {
    /// A folder of its own, spelled out in full: this sits in a bucket the listener
    /// browses in every storage client they own, often years later, and ".byop" tells them
    /// nothing about which app left it there or whether it's safe to delete.
    private var backupFolder: String { (rootFolder ?? "") + "ear-to-listen-podcasts/" }

    /// Where the app kept them under its old name. Read, never written — a rename must
    /// not strand the copies already in someone's bucket.
    private var legacyBackupFolder: String { (rootFolder ?? "") + "bring-your-own-podcasts/" }

    /// Names this backup has had before. Read-only, in order, so a copy written by any
    /// older build still restores — losing track of one means losing the library it holds.
    ///
    /// `app-data-backup.zip` was the single file every build wrote before dated
    /// archives; `.byop/library-backup.zip` was an abbreviation nobody could expand; the
    /// `.json` before that was a zip with a lying extension, chosen only to fall outside
    /// the old "is this an episode" filter, which `FileKind` now decides properly.
    private var legacyBackupKeys: [String] {
        [
            legacyBackupFolder + "app-data-backup.zip",
            (rootFolder ?? "") + ".byop/library-backup.zip",
            (rootFolder ?? "") + "byop-backup.json",
        ]
    }

    /// Today's archive — see `BackupArchiveName`. Derived rather than picked, so backing
    /// up and restoring still need no picker.
    func uploadBackup(_ data: Data) async throws {
        try await uploadBackup(data, named: BackupArchiveName.current())
    }

    func uploadBackup(_ data: Data, named name: String) async throws {
        try await upload(
            data, toPath: backupFolder + name, contentType: "application/zip"
        )
    }

    /// `nil` means no backup has been made yet, not an error. Reads the newest archive in
    /// either folder — not necessarily this month's, since a device coming back from a
    /// reinstall may not have backed up yet — and falls back to the keys older builds
    /// wrote so those copies still restore.
    ///
    /// `acceptable` decides whether a copy that downloaded is the one to use. A newer
    /// archive holding nothing — what a wipe of an already-empty library used to leave —
    /// is skipped for the one under it rather than returned as the answer.
    func downloadBackup(acceptable: (Data) -> Bool = { !$0.isEmpty }) async throws -> Data? {
        var names: [String] = []
        for folder in [backupFolder, legacyBackupFolder] {
            names += ((try? await listFiles(inFolder: folder)) ?? []).map(\.path)
        }
        for key in BackupArchiveName.preferred(among: names) + legacyBackupKeys {
            guard let data = try? await download(fileID: key) else { continue }
            if acceptable(data) { return data }
        }
        return nil
    }
}
