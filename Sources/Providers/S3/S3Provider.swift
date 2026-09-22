import Foundation

enum S3ProviderError: Error, LocalizedError {
    case unsupportedKind(String)
    case regionDetectionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let type):
            return "\(type) buckets aren't served by the S3 client."
        case .regionDetectionFailed:
            return "Couldn't detect the bucket's region. Check the bucket name is correct."
        }
    }
}

/// Amazon S3, Tencent Cloud COS and Alibaba Cloud OSS.
///
/// One implementation for three clouds, because they are one API: the same requests, the
/// same SigV4 signature (service `s3`) and the same XML, answered on three different
/// hostnames. Which host is the only thing that varies, and it varies in `BucketEndpoint`.
struct S3Provider: CloudProvider {
    let type: String
    let rootFolder: String?

    private let client: S3RestClient

    init(config: CloudProviderConfig) throws {
        guard let kind = config.kind, kind.speaksS3 else {
            throw S3ProviderError.unsupportedKind(config.type)
        }
        let accessKeyId = try config.required("accessKeyId")
        let secretAccessKey = try config.required("secretAccessKey")
        let region = try config.required("region")
        let bucket = try config.required("bucket")
        guard let endpoint = BucketEndpoint(kind: kind, bucket: bucket, region: region) else {
            throw S3ProviderError.unsupportedKind(config.type)
        }

        type = kind.providerType
        rootFolder = config.folder
        client = S3RestClient(
            endpoint: endpoint,
            credentials: SigV4.Credentials(
                accessKeyID: accessKeyId, secretAccessKey: secretAccessKey, region: region
            )
        )
    }

    /// Looks up which region a bucket lives in, so the add-provider flow doesn't require typing it
    /// or granting any IAM permission: S3 returns this header for any request to a bucket's
    /// virtual-hosted endpoint, even unauthenticated ones, before permission checks happen.
    ///
    /// AWS only — COS and OSS name the region in the hostname itself, so there's nowhere to
    /// ask before you already know it, and those connections pick it from a list instead.
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
                prefix: folderID ?? rootFolder, continuationToken: continuationToken
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

    /// One folder level, asked of the bucket directly: `delimiter: "/"` makes it return
    /// immediate subfolders as `commonPrefixes` and only the keys sitting in this folder,
    /// instead of every key underneath it. That's what makes live browsing affordable — the
    /// default implementation would pull the whole subtree back just to show one level of it.
    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let prefix = CloudFolderPath.normalized(folderID) ?? rootFolder ?? ""
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

    /// The signed GET the default would mint works, but this is already a signed request
    /// and one round trip either way — no reason to sign a URL to hand back to ourselves.
    func download(fileID: String) async throws -> Data {
        try await client.getObject(key: fileID)
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await client.listObjects(prefix: rootFolder, maxKeys: 1)
            return ConnectionTestResult(isSuccess: true, message: nil)
        } catch {
            return ConnectionTestResult(isSuccess: false, message: describeCloudError(error))
        }
    }

    var isWritable: Bool { true }

    /// `path` is a whole key, as `listFiles` hands them out — not relative to the folder
    /// this connection starts at.
    func write(_ data: Data, toPath path: String, contentType: String) async throws {
        try await client.putObject(key: path, data: data, contentType: contentType)
    }
}
