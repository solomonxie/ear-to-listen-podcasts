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

    /// Default folder new buckets are scoped to, so users don't have to think of one.
    static let defaultKeyPrefix = "BringYourOwnPodcasts/"

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
        keyPrefix = config.settings["keyPrefix"].flatMap { $0.isEmpty ? nil : $0 }

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
                    modifiedAt: object.lastModified
                ))
            }
            continuationToken = (output.isTruncated ?? false) ? output.nextContinuationToken : nil
        } while continuationToken != nil
        return files
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let output = try await client.headObject(input: HeadObjectInput(bucket: bucket, key: fileID))
        return CloudFile(
            id: fileID,
            name: fileID.split(separator: "/").last.map(String.init) ?? fileID,
            path: fileID,
            sizeBytes: output.contentLength.map(Int64.init),
            mimeType: output.contentType,
            modifiedAt: output.lastModified
        )
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        try await client.presignedURLForGetObject(
            input: GetObjectInput(bucket: bucket, key: fileID),
            expiration: 3600
        )
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await client.listObjectsV2(input: ListObjectsV2Input(bucket: bucket, maxKeys: 1))
            return ConnectionTestResult(isSuccess: true, message: nil)
        } catch {
            return ConnectionTestResult(isSuccess: false, message: describeAWSError(error))
        }
    }
}
