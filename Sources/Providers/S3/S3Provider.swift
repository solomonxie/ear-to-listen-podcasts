import AWSClientRuntime
import AWSS3
import AWSSDKIdentity
import ClientRuntime
import Foundation

/// `error.localizedDescription` on AWS SDK errors bridges to a generic NSError
/// string ("The operation couldn't be completed...") that drops the actual AWS
/// error code/message/status, so unwrap those explicitly for anything useful to show.
func describeAWSError(_ error: Error) -> String {
    if let serviceError = error as? AWSServiceError {
        var parts: [String] = []
        if let code = serviceError.errorCode { parts.append(code) }
        if let message = serviceError.message { parts.append(message) }
        if let httpError = error as? HTTPError {
            parts.append("(HTTP \(httpError.httpResponse.statusCode.rawValue))")
        }
        if !parts.isEmpty { return parts.joined(separator: ": ") }
    }
    return error.localizedDescription
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
    private let client: S3Client

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

        let identity = AWSCredentialIdentity(accessKey: accessKeyId, secret: secretAccessKey)
        let resolver = StaticAWSCredentialIdentityResolver(identity)
        let clientConfig = try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        client = S3Client(config: clientConfig)
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
            let output = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                prefix: folderID ?? keyPrefix
            ))
            for object in output.contents ?? [] {
                guard let key = object.key else { continue }
                files.append(CloudFile(
                    id: key,
                    name: key.split(separator: "/").last.map(String.init) ?? key,
                    path: key,
                    sizeBytes: object.size.map(Int64.init),
                    mimeType: nil,
                    modifiedAt: object.lastModified,
                    contentHash: unquoted(object.eTag)
                ))
            }
            continuationToken = (output.isTruncated ?? false) ? output.nextContinuationToken : nil
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
            let output = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                prefix: prefix
            ))
            for common in output.commonPrefixes ?? [] {
                guard let path = common.prefix, path != prefix else { continue }
                // Whole key, minus the trailing slash: that's what gets passed back in to
                // list the next level down.
                folders.append(String(path.dropLast(path.hasSuffix("/") ? 1 : 0)))
            }
            for object in output.contents ?? [] {
                // A folder created through the console is a zero-byte key ending in "/" —
                // that's the folder itself, not a file in it.
                guard let key = object.key, key != prefix, !key.hasSuffix("/") else { continue }
                files.append(CloudFile(
                    id: key,
                    name: (key as NSString).lastPathComponent,
                    path: key,
                    sizeBytes: object.size.map(Int64.init),
                    mimeType: nil,
                    modifiedAt: object.lastModified,
                    contentHash: unquoted(object.eTag)
                ))
            }
            continuationToken = (output.isTruncated ?? false) ? output.nextContinuationToken : nil
        } while continuationToken != nil
        return (folders.sorted(), files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let output = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: fileID))
        return CloudFile(
            id: fileID,
            name: fileID.split(separator: "/").last.map(String.init) ?? fileID,
            path: fileID,
            sizeBytes: output.contentLength.map(Int64.init),
            mimeType: output.contentType,
            modifiedAt: output.lastModified,
            contentHash: unquoted(output.eTag)
        )
    }

    /// S3 wraps ETags in literal double quotes (`"\"abc123\""`); strip them so the stored
    /// value is a plain comparable hash.
    private func unquoted(_ etag: String?) -> String? {
        etag?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        try await client.presignedURLForGetObject(
            input: GetObjectInput(bucket: bucket, key: fileID),
            expiration: 3600
        )
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await client.listObjectsV2(input: ListObjectsV2Input(bucket: bucket, maxKeys: 1, prefix: keyPrefix))
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
        _ = try await client.putObject(input: PutObjectInput(
            body: .data(data), bucket: bucket, contentType: contentType, key: key
        ))
    }

    func uploadBackup(_ data: Data) async throws {
        _ = try await client.putObject(input: PutObjectInput(
            body: .data(data), bucket: bucket, contentType: "application/zip", key: backupKey
        ))
    }

    /// `nil` means no backup has been made yet, not an error. Reads the newest month in
    /// the folder — not necessarily this month's, since a device coming back from a
    /// reinstall may not have backed up yet — and falls back to the keys older builds
    /// wrote so those copies still restore.
    func downloadBackup() async throws -> Data? {
        let newest = (try? await newestBackupKey()) ?? nil
        for key in (newest.map { [$0] } ?? []) + legacyBackupKeys {
            do {
                let output = try await client.getObject(input: GetObjectInput(bucket: bucket, key: key))
                if let data = try await output.body?.readData() { return data }
            } catch let error as AWSServiceError where error.errorCode == "NoSuchKey" {
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
            let output = try? await client.listObjectsV2(input: ListObjectsV2Input(bucket: bucket, prefix: prefix))
            keys += (output?.contents ?? []).compactMap(\.key)
        }
        return BackupArchiveName.newest(among: keys)
    }
}
