import XCTest
@testable import EarToListen

final class BucketEndpointTests: XCTestCase {
    private func host(_ kind: CloudSourceKind, _ bucket: String, _ region: String) -> String? {
        BucketEndpoint(kind: kind, bucket: bucket, region: region)?.host
    }

    func testEachCloudAnswersOnItsOwnHost() {
        XCTAssertEqual(host(.amazonS3, "podcasts", "eu-west-1"), "podcasts.s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(host(.tencentCos, "podcasts-1250000000", "ap-guangzhou"), "podcasts-1250000000.cos.ap-guangzhou.myqcloud.com")
        XCTAssertEqual(host(.aliyunOss, "podcasts", "cn-hangzhou"), "podcasts.s3.oss-cn-hangzhou.aliyuncs.com")
    }

    /// A dotted bucket name breaks certificate matching on `*.s3.region.amazonaws.com`, so
    /// the bucket moves into the path instead.
    func testADottedAwsBucketGoesPathStyle() {
        let endpoint = BucketEndpoint(kind: .amazonS3, bucket: "my.podcasts", region: "us-east-1")
        XCTAssertEqual(endpoint?.host, "s3.us-east-1.amazonaws.com")
        XCTAssertEqual(endpoint?.usesPathStyle, true)
    }

    func testCloudsThatDontSpeakS3HaveNoEndpoint() {
        XCTAssertNil(BucketEndpoint(kind: .azureBlob, bucket: "podcasts", region: ""))
        XCTAssertNil(BucketEndpoint(kind: .googleCloudStorage, bucket: "podcasts", region: ""))
    }

    /// The raw value is the stored `ProviderRecord.type`, so the connections made before
    /// any other cloud existed have to keep resolving.
    func testAStoredS3TypeStillNamesAmazon() {
        XCTAssertEqual(CloudSourceKind(providerType: "s3"), .amazonS3)
        XCTAssertNil(CloudSourceKind(providerType: "local"))
    }
}
