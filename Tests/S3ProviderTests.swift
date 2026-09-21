import XCTest
@testable import EarToListen

final class S3ProviderTests: XCTestCase {
    private func config(_ settings: [String: String], kind: CloudSourceKind = .amazonS3) -> CloudProviderConfig {
        CloudProviderConfig(id: "test", type: kind.providerType, label: "Test", settings: settings)
    }

    func testMissingAccessKeyThrows() {
        let settings = config(["secretAccessKey": "s", "region": "us-east-1", "bucket": "b"])
        XCTAssertThrowsError(try S3Provider(config: settings)) { error in
            guard case CloudProviderError.missingSetting(let key) = error else {
                return XCTFail("expected missingSetting, got \(error)")
            }
            XCTAssertEqual(key, "accessKeyId")
        }
    }

    func testMissingBucketThrows() {
        let settings = config(["accessKeyId": "a", "secretAccessKey": "s", "region": "us-east-1"])
        XCTAssertThrowsError(try S3Provider(config: settings)) { error in
            guard case CloudProviderError.missingSetting(let key) = error else {
                return XCTFail("expected missingSetting, got \(error)")
            }
            XCTAssertEqual(key, "bucket")
        }
    }

    func testEmptyStringSettingCountsAsMissing() {
        let settings = config(["accessKeyId": "", "secretAccessKey": "s", "region": "us-east-1", "bucket": "b"])
        XCTAssertThrowsError(try S3Provider(config: settings))
    }

    func testFullSettingsConstructSuccessfully() throws {
        let settings = config(["accessKeyId": "a", "secretAccessKey": "s", "region": "us-east-1", "bucket": "b"])
        let provider = try S3Provider(config: settings)
        XCTAssertEqual(provider.type, CloudSourceKind.amazonS3.providerType)
    }

    /// COS and OSS are the same provider — a stored record only differs by its type.
    func testTheOtherS3CloudsBuildTheSameProvider() throws {
        for kind in [CloudSourceKind.tencentCos, .aliyunOss] {
            let provider = try S3Provider(config: config(
                ["accessKeyId": "a", "secretAccessKey": "s", "region": "ap-guangzhou", "bucket": "b"], kind: kind
            ))
            XCTAssertEqual(provider.type, kind.providerType)
        }
    }

    func testANonS3CloudIsRefused() {
        let settings = config(
            ["accessKeyId": "a", "secretAccessKey": "s", "region": "r", "bucket": "b"], kind: .azureBlob
        )
        XCTAssertThrowsError(try S3Provider(config: settings))
    }

    /// The folder is normalized on read, so a connection stored before folders had to end
    /// in a slash still addresses a folder rather than a name fragment.
    func testFolderIsNormalizedOnRead() throws {
        let provider = try S3Provider(config: config([
            "accessKeyId": "a", "secretAccessKey": "s", "region": "us-east-1", "bucket": "b",
            "keyPrefix": "/podcasts",
        ]))
        XCTAssertEqual(provider.rootFolder, "podcasts/")
    }
}
