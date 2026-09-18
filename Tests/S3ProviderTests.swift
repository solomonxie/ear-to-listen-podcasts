import XCTest
@testable import EarToListen

final class S3ProviderTests: XCTestCase {
    private func config(_ settings: [String: String]) -> CloudProviderConfig {
        CloudProviderConfig(id: "test", type: S3Provider.providerType, label: "Test", settings: settings)
    }

    func testMissingAccessKeyThrows() {
        let settings = config(["secretAccessKey": "s", "region": "us-east-1", "bucket": "b"])
        XCTAssertThrowsError(try S3Provider(config: settings)) { error in
            guard case S3ProviderError.missingSetting(let key) = error else {
                return XCTFail("expected missingSetting, got \(error)")
            }
            XCTAssertEqual(key, "accessKeyId")
        }
    }

    func testMissingBucketThrows() {
        let settings = config(["accessKeyId": "a", "secretAccessKey": "s", "region": "us-east-1"])
        XCTAssertThrowsError(try S3Provider(config: settings)) { error in
            guard case S3ProviderError.missingSetting(let key) = error else {
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
        XCTAssertEqual(provider.type, S3Provider.providerType)
    }
}
