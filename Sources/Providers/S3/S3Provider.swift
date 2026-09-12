import AWSS3
import AWSSDKIdentity
import Foundation

enum S3ProviderError: Error {
    case missingSetting(String)
}

struct S3Provider: CloudProvider {
    static let providerType = "s3"
    let type = S3Provider.providerType

    private let bucket: String
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

        let identity = AWSCredentialIdentity(accessKey: accessKeyId, secret: secretAccessKey)
        let resolver = StaticAWSCredentialIdentityResolver(identity)
        let clientConfig = try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        client = S3Client(config: clientConfig)
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        var continuationToken: String?
        repeat {
            let output = try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                prefix: folderID
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
            return ConnectionTestResult(isSuccess: false, message: error.localizedDescription)
        }
    }
}
