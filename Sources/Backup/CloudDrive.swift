import Foundation

/// Why the app's iCloud folder can't be written to. All four arrive as the same nil
/// container, and each needs something different said about it — report them as one and
/// you end up telling someone to sign in to iCloud when they already are.
enum CloudDriveStatus: Equatable {
    case ready
    /// Built without the iCloud capability — every free-team build. Nothing the listener
    /// can do, so the row says so and offers no instruction.
    case notEntitled
    /// Signed out of iCloud, or iCloud Drive switched off. The one state with directions.
    case driveOff
    /// Entitled and signed in, but the container hasn't appeared yet.
    case notReady

    var isReady: Bool { self == .ready }
}

enum CloudDriveError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? { "This device's iCloud folder isn't available." }
}

/// The app's own folder in the listener's iCloud Drive: the one backup destination with
/// nothing to set up, and one that outlives deleting the app.
///
/// Archives only — the zip `BackupService` builds, never the live SQLite file. iCloud
/// syncs file-at-a-time and knows nothing about WAL sidecars, so pointing it at the
/// working database buys `ear-to-listen 2.sqlite` conflict copies and corruption.
///
/// One file per day (`BackupArchiveName`), and the latest ten are kept — older ones are
/// deleted on the way past. Count, not age, because this is the tier the listener pays
/// for: a count is what bounds the bill and what keeps a folder they open in Files from
/// becoming a pile. Ten days back is far enough that a mistake noticed the following week
/// still has a copy from before it.
enum CloudDrive {
    static let containerID = "iCloud.com.solomonxie.eartolisten"

    /// The container this app used under its old name. Still listed in the entitlements
    /// and still read, so a library backed up before the rename comes back by itself —
    /// renaming an app must not strand the copies it already took.
    static let legacyContainerID = "iCloud.com.solomonxie.byopo"

    /// What every build before monthly archives wrote, read so those copies still restore.
    static let legacyBackupFileName = "byo-podcasts-backup.zip"

    /// `nonisolated async` throughout: resolving the container and reading it hit the
    /// filesystem and iCloud's daemon, which is not something to do on the main actor.

    static func status() async -> CloudDriveStatus {
        if documentsURL() != nil { return .ready }
        // Order matters. `ubiquityIdentityToken` needs the iCloud entitlement itself, so
        // in an unentitled build it reads nil and is indistinguishable from a signed-out
        // account — check the build first or the signal lies.
        guard BuildSigning.hasCloudEntitlement else { return .notEntitled }
        guard FileManager.default.ubiquityIdentityToken != nil else { return .driveOff }
        return .notReady
    }

    /// How many days back this destination keeps. The bucket is where "what did this look
    /// like in March" lives; here, ten is what a phone's worth of mistakes needs.
    static let keptArchives = 10

    static func write(_ archive: Data) async throws {
        guard let documents = documentsURL() else { throw CloudDriveError.unavailable }
        try archive.write(to: documents.appending(path: BackupArchiveName.current()), options: .atomic)
        prune(in: documents)
    }

    /// Drops everything past the newest `keptArchives`. Undownloaded copies sit under a
    /// hidden placeholder name, so they're ranked by the name they'll have and deleted by
    /// the one they have now.
    private static func prune(in documents: URL) {
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        let onDisk = Dictionary(
            listed.map { (realName(ofPlaceholder: $0), $0) }, uniquingKeysWith: { first, _ in first }
        )
        let oldestFirst = BackupArchiveName.oldestFirst(among: onDisk.keys)
        guard oldestFirst.count > keptArchives else { return }
        for name in oldestFirst.prefix(oldestFirst.count - keptArchives) {
            guard let fileName = onDisk[name] else { continue }
            try? FileManager.default.removeItem(at: documents.appending(path: fileName))
        }
    }

    /// The backup, waiting for iCloud to fetch it if it's still a placeholder — which, on
    /// the fresh install this exists for, it always is.
    static func latestBackup(timeout: TimeInterval = 30) async throws -> Data? {
        guard let documents = documentsURL() ?? documentsURL(of: legacyContainerID) else {
            throw CloudDriveError.unavailable
        }
        guard let fileName = newestBackupFileName(in: documents) else {
            // Nothing under the new name — look where the old one kept them.
            guard let legacy = documentsURL(of: legacyContainerID), legacy != documents,
                  let fileName = newestBackupFileName(in: legacy)
            else { return nil }
            return try await read(fileName, in: legacy, timeout: timeout)
        }
        return try await read(fileName, in: documents, timeout: timeout)
    }

    private static func read(_ fileName: String, in documents: URL, timeout: TimeInterval) async throws -> Data? {
        let url = documents.appending(path: fileName)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let archive = try? Data(contentsOf: url), !archive.isEmpty { return archive }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline && !Task.isCancelled
        return nil
    }

    /// The newest day's archive that's there — or the one older builds wrote, if that's
    /// all there is. Undownloaded files show up under a hidden placeholder name rather
    /// than their own, so those count too; the read below is what waits for the bytes.
    private static func newestBackupFileName(in documents: URL) -> String? {
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        let names = listed.map(realName(ofPlaceholder:))
        if let newest = BackupArchiveName.newest(among: names) { return newest }
        let legacy = documents.appending(path: legacyBackupFileName)
        guard FileManager.default.fileExists(atPath: legacy.path) || placeholderExists(for: legacy) else { return nil }
        return legacyBackupFileName
    }

    /// `.202609-ear-to-listen.zip.icloud` is how iCloud names a file it hasn't fetched yet.
    private static func realName(ofPlaceholder name: String) -> String {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    private static func documentsURL(of identifier: String? = nil) -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: identifier ?? containerID) else { return nil }
        let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// A file iCloud hasn't downloaded yet sits under a hidden placeholder name, so the
    /// real one doesn't exist on disk — which is exactly the state a fresh install finds.
    private static func placeholderExists(for url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }
}

/// Whether this build carries the iCloud capability, read out of the embedded
/// provisioning profile: `SecTaskCopyValueForEntitlement` isn't in the iOS SDK, and
/// without this every free-team build looks exactly like a signed-out account.
private enum BuildSigning {
    static let hasCloudEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url)
        else {
            return true // App Store builds ship no profile.
        }
        guard let entitlements = plist(in: profile)?["Entitlements"] as? [String: Any],
              let containers = entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String]
        else { return false }
        return !containers.isEmpty
    }()

    /// The profile is a CMS-signed blob with an XML plist sitting in the middle of it.
    private static func plist(in profile: Data) -> [String: Any]? {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.upperBound..<profile.endIndex)
        else { return nil }
        let xml = Data(profile[start.lowerBound..<end.upperBound])
        return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
    }
}
