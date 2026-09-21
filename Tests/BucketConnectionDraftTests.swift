import XCTest
@testable import EarToListen

final class BucketConnectionDraftTests: XCTestCase {
    /// A folder is the only thing a connection can point at: a bare `pod` would also match
    /// `podcasts-old/`, so the trailing slash is added rather than asked for again.
    func testFolderPathsAlwaysEndInASlash() {
        XCTAssertEqual(CloudFolderPath.normalized("podcasts"), "podcasts/")
        XCTAssertEqual(CloudFolderPath.normalized("podcasts/"), "podcasts/")
        XCTAssertEqual(CloudFolderPath.normalized("/podcasts/2019"), "podcasts/2019/")
        XCTAssertEqual(CloudFolderPath.normalized("  podcasts//2019//  "), "podcasts/2019/")
    }

    /// Empty means the whole bucket, not a folder called "".
    func testAnEmptyFolderPathIsNil() {
        XCTAssertNil(CloudFolderPath.normalized(nil))
        XCTAssertNil(CloudFolderPath.normalized(""))
        XCTAssertNil(CloudFolderPath.normalized("   "))
        XCTAssertNil(CloudFolderPath.normalized("/"))
    }

    func testAPastedFolderIsNormalizedAsItLands() {
        let draft = BucketConnectionDraft.parse("bucket: my-archive\nfolder: podcasts")

        XCTAssertEqual(draft.keyPrefix, "podcasts/")
    }

    func testParsesTheDocumentedBlock() {
        let draft = BucketConnectionDraft.parse("""
            bucket: my-archive
            prefix: podcasts/
            access_key_id: AKIAEXAMPLE
            secret_access_key: wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
            """)

        XCTAssertEqual(draft.bucket, "my-archive")
        XCTAssertEqual(draft.keyPrefix, "podcasts/")
        XCTAssertEqual(draft.accessKeyId, "AKIAEXAMPLE")
        XCTAssertEqual(draft.secretAccessKey, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    }

    /// An AWS CLI credentials file pasted as-is: `=`, a profile header, and the
    /// `aws_`-prefixed key names.
    func testParsesAnAwsCredentialsFileStanza() {
        let draft = BucketConnectionDraft.parse("""
            [default]
            aws_access_key_id = AKIAEXAMPLE
            aws_secret_access_key = secret+value/with=padding
            """)

        XCTAssertEqual(draft.accessKeyId, "AKIAEXAMPLE")
        XCTAssertEqual(draft.secretAccessKey, "secret+value/with=padding")
    }

    func testKeySpellingAndQuotesDoNotMatter() {
        let draft = BucketConnectionDraft.parse("""
            # my bucket
            Bucket Name: "my-archive"
            - Access Key ID: 'AKIAEXAMPLE',
            """)

        XCTAssertEqual(draft.bucket, "my-archive")
        XCTAssertEqual(draft.accessKeyId, "AKIAEXAMPLE")
        XCTAssertNil(draft.secretAccessKey)
    }

    func testTextWithNothingRecognisableParsesToNothing() {
        XCTAssertTrue(BucketConnectionDraft.parse("just some notes\nno pairs here").isEmpty)
    }
}
