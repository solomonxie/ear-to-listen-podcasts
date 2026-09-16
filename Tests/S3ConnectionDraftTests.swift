import XCTest
@testable import BringYourOwnPodcasts

final class S3ConnectionDraftTests: XCTestCase {
    func testParsesTheDocumentedBlock() {
        let draft = S3ConnectionDraft.parse("""
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
        let draft = S3ConnectionDraft.parse("""
            [default]
            aws_access_key_id = AKIAEXAMPLE
            aws_secret_access_key = secret+value/with=padding
            """)

        XCTAssertEqual(draft.accessKeyId, "AKIAEXAMPLE")
        XCTAssertEqual(draft.secretAccessKey, "secret+value/with=padding")
    }

    func testKeySpellingAndQuotesDoNotMatter() {
        let draft = S3ConnectionDraft.parse("""
            # my bucket
            Bucket Name: "my-archive"
            - Access Key ID: 'AKIAEXAMPLE',
            """)

        XCTAssertEqual(draft.bucket, "my-archive")
        XCTAssertEqual(draft.accessKeyId, "AKIAEXAMPLE")
        XCTAssertNil(draft.secretAccessKey)
    }

    func testTextWithNothingRecognisableParsesToNothing() {
        XCTAssertTrue(S3ConnectionDraft.parse("just some notes\nno pairs here").isEmpty)
    }
}
