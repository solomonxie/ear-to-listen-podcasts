import Foundation

/// The code S3 actually returned — `AccessDenied`, `SignatureDoesNotMatch`, `NoSuchKey` —
/// rather than a generic "the operation couldn't be completed". Which of those it is, is
/// the whole content of the message for someone whose bucket won't connect.
func describeAWSError(_ error: Error) -> String {
    error.localizedDescription
}

enum S3ProviderError: Error, LocalizedError {
    case missingSetting(String)
    case regionDetectionFailed

    var errorDescription: String? {
        switch self {
        case .missingSetting(let key):
            return "Missing setting: \(key)"
        case .regionDetectionFailed:
            return "Couldn't detect the bucket's region. Check the bucket name is correct."
        }
    }
}

struct S3Provider: CloudProvider {
    static let providerType = "s3"
    let type = S3Provider.providerType

    private let bucket: String
    private let keyPrefix: String?
    private let client: S3RestClient

    init(config: CloudProviderConfig) throws {
        func setting(_ key: String) throws -> String {
            guard let value = config.settings[key], !value.isEmpty else {
                throw S3ProviderError.missingSetting(key)
            }
            return value
        }

        let accessKeyId = try setting("accessKeyId")
        let secretAccessKey = try setting("secretAccessKey")
        let region = try setting("region")
        bucket = try setting("bucket")
        // Normalized on read as well as on save, so connections stored before folders were
        // required (a prefix with no trailing slash) start behaving like folders too.
        keyPrefix = S3FolderPath.normalized(config.settings["keyPrefix"])

        client = S3RestClient(
            bucket: bucket,
            credentials: SigV4.Credentials(
                accessKeyID: accessKeyId, secretAccessKey: secretAccessKey, region: region
            )
        )
    }

    /// Looks up which region a bucket lives in, so the add-provider flow doesn't require typing it
    /// or granting any IAM permission: S3 returns this header for any request to a bucket's
    /// virtual-hosted endpoint, even unauthenticated ones, before permission checks happen.
    static func detectRegion(bucket: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://\(bucket).s3.amazonaws.com/")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let region = http.value(forHTTPHeaderField: "x-amz-bucket-region") else {
            throw S3ProviderError.regionDetectionFailed
        }
        return region
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        var continuationToken: String?
        repeat {
            let output = try await client.listObjects(
                prefix: folderID ?? keyPrefix, continuationToken: continuationToken
            )
            for object in output.objects {
                files.append(CloudFile(
                    id: object.key,
                    name: object.key.split(separator: "/").last.map(String.init) ?? object.key,
                    path: object.key,
                    sizeBytes: object.size,
                    mimeType: nil,
                    modifiedAt: object.lastModified,
                    contentHash: object.eTag
                ))
            }
            continuationToken = output.nextContinuationToken
        } while continuationToken != nil
        return files
    }

    /// One folder level, asked of S3 directly: `delimiter: "/"` makes it return immediate
    /// subfolders as `commonPrefixes` and only the keys sitting in this folder, instead of
    /// every key underneath it. That's what makes live browsing affordable — the default
    /// implementation would pull the whole subtree back just to show one level of it.
    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let prefix = S3FolderPath.normalized(folderID) ?? keyPrefix ?? ""
        var folders: [String] = []
        var files: [CloudFile] = []
        var continuationToken: String?
        repeat {
            let output = try await client.listObjects(
                prefix: prefix, delimiter: "/", continuationToken: continuationToken
            )
            for path in output.commonPrefixes where path != prefix {
                // Whole key, minus the trailing slash: that's what gets passed back in to
                // list the next level down.
                folders.append(String(path.dropLast(path.hasSuffix("/") ? 1 : 0)))
            }
            for object in output.objects {
                // A folder created through the console is a zero-byte key ending in "/" —
                // that's the folder itself, not a file in it.
                guard object.key != prefix, !object.key.hasSuffix("/") else { continue }
                files.append(CloudFile(
                    id: object.key,
                    name: (object.key as NSString).lastPathComponent,
                    path: object.key,
                    sizeBytes: object.size,
                    mimeType: nil,
                    modifiedAt: object.lastModified,
                    contentHash: object.eTag
                ))
            }
            continuationToken = output.nextContinuationToken
        } while continuationToken != nil
        return (folders.sorted(), files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let output = try await client.headObject(key: fileID)
        return CloudFile(
            id: fileID,
            name: fileID.split(separator: "/").last.map(String.init) ?? fileID,
            path: fileID,
            sizeBytes: output.size,
            mimeType: output.contentType,
            modifiedAt: output.lastModified,
            // S3 wraps ETags in literal double quotes; stored as a plain comparable hash.
            contentHash: output.eTag?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        )
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        guard let url = client.presignedGetURL(key: fileID) else { throw S3Error.malformedResponse }
        return url
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await client.listObjects(prefix: keyPrefix, maxKeys: 1)
            return ConnectionTestResult(isSuccess: true, message: nil)
        } catch {
            return ConnectionTestResult(isSuccess: false, message: describeAWSError(error))
        }
    }

    /// A folder of its own, spelled out in full: this sits in a bucket the listener
    /// browses in every S3 client they own, often years later, and ".byop" tells them
    /// nothing about which app left it there or whether it's safe to delete.
    private var backupFolder: String { (keyPrefix ?? "") + "ear-to-listen-podcasts/" }

    /// Where the app kept them under its old name. Read, never written — a rename must
    /// not strand the copies already in someone's bucket.
    private var legacyBackupFolder: String { (keyPrefix ?? "") + "bring-your-own-podcasts/" }

    /// Today's archive — see `BackupArchiveName`. Derived rather than picked, so
    /// backing up and restoring still need no picker.
    private var backupKey: String { backupFolder + BackupArchiveName.current() }

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
            (keyPrefix ?? "") + ".byop/library-backup.zip",
            (keyPrefix ?? "") + "byop-backup.json",
        ]
    }

    var isWritable: Bool { true }

    /// `path` is a whole key, as `listFiles` hands them out — not relative to `keyPrefix`.
    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        let key = try CloudWrite.checked(path)
        try await client.putObject(key: key, data: data, contentType: contentType)
    }

    func uploadBackup(_ data: Data) async throws {
        try await client.putObject(key: backupKey, data: data, contentType: "application/zip")
    }

    /// `nil` means no backup has been made yet, not an error. Reads the newest month in
    /// the folder — not necessarily this month's, since a device coming back from a
    /// reinstall may not have backed up yet — and falls back to the keys older builds
    /// wrote so those copies still restore.
    func downloadBackup() async throws -> Data? {
        let newest = (try? await newestBackupKey()) ?? nil
        for key in (newest.map { [$0] } ?? []) + legacyBackupKeys {
            do {
                return try await client.getObject(key: key)
            } catch let error as S3Error where error.code == "NoSuchKey" || error.code == "NoSuchBucket" {
                continue
            }
        }
        return nil
    }

    /// The newest archive in either folder — the app's own, and the one it used to write
    /// to. Both are listed rather than one falling back to the other: whichever holds the
    /// most recent copy is the one to restore from.
    private func newestBackupKey() async throws -> String? {
        var keys: [String] = []
        for prefix in [backupFolder, legacyBackupFolder] {
            let output = try? await client.listObjects(prefix: prefix)
            keys += (output?.objects ?? []).map(\.key)
        }
        return BackupArchiveName.newest(among: keys)
    }
}
