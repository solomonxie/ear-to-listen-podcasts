import XCTest
@testable import EarToListen

/// Signing is the one part of talking to S3 that can't be "nearly right" — a canonical
/// request that differs by one character is rejected with `SignatureDoesNotMatch` and no
/// hint as to which character. These check the pieces against AWS's own documented values
/// so a mistake shows up here rather than as a bucket that mysteriously won't connect.
final class SigV4Tests: XCTestCase {
    /// From *Signature Version 4 signing process* — the `aws4_request` example, whose
    /// intermediate values AWS publishes.
    private let credentials = SigV4.Credentials(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1"
    )

    func testSha256OfAnEmptyBodyMatchesTheDocumentedConstant() {
        XCTAssertEqual(
            SigV4.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// The encoding rules are stricter than `addingPercentEncoding`'s: only
    /// `A-Za-z0-9-_.~` survive, everything else is uppercase percent-hex.
    func testEncodingFollowsTheAwsRulesNotFoundations() {
        XCTAssertEqual(SigV4.encode("a b"), "a%20b")
        XCTAssertEqual(SigV4.encode("a+b"), "a%2Bb")
        XCTAssertEqual(SigV4.encode("a=b&c"), "a%3Db%26c")
        XCTAssertEqual(SigV4.encode("~_-."), "~_-.")
        XCTAssertEqual(SigV4.encode("ä"), "%C3%A4")
    }

    /// A key is a path, and its slashes must survive — encoding them turns
    /// `folder/ep.mp3` into a single object literally named with `%2F`.
    func testSlashesSurviveWhenEncodingAPath() {
        XCTAssertEqual(SigV4.encode("a/b c/d.mp3", encodeSlash: false), "a/b%20c/d.mp3")
        XCTAssertEqual(SigV4.encode("a/b", encodeSlash: true), "a%2Fb")
    }

    /// Canonical query order is by *encoded* name, and every value is encoded too.
    func testCanonicalQueryIsSortedAndEncoded() {
        let query = SigV4.canonicalQuery([
            ("prefix", "a b/"), ("list-type", "2"), ("delimiter", "/"),
        ])

        XCTAssertEqual(query, "delimiter=%2F&list-type=2&prefix=a%20b%2F")
    }

    func testDatesUseTheFormatsTheAlgorithmSpecifies() {
        let date = Date(timeIntervalSince1970: 1_440_938_160)  // 2015-08-30T12:36:00Z

        XCTAssertEqual(SigV4.amzDate(date), "20150830T123600Z")
        XCTAssertEqual(SigV4.dateStamp(date), "20150830")
    }

    // MARK: Signed requests

    private func signedRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/a/ep.mp3")!)
        request.httpMethod = "GET"
        SigV4.sign(
            &request, payload: Data(), credentials: credentials,
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )
        return request
    }

    func testASignedRequestCarriesEverythingS3ChecksFor() {
        let request = signedRequest()
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

        XCTAssertTrue(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"))
        XCTAssertTrue(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(authorization.contains("Signature="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20150830T123600Z")
        // S3 rejects a signed request that doesn't declare its payload hash.
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// Same inputs, same signature — if this drifts, nothing else here means anything.
    func testSigningIsDeterministic() {
        let first = signedRequest().value(forHTTPHeaderField: "Authorization")
        let second = signedRequest().value(forHTTPHeaderField: "Authorization")

        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    func testADifferentSecretProducesADifferentSignature() {
        var other = credentials
        var request = URLRequest(url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/a")!)
        request.httpMethod = "GET"
        other = SigV4.Credentials(
            accessKeyID: credentials.accessKeyID, secretAccessKey: "different", region: credentials.region
        )
        SigV4.sign(&request, payload: Data(), credentials: other, now: Date(timeIntervalSince1970: 1_440_938_160))

        XCTAssertNotEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            signedRequest().value(forHTTPHeaderField: "Authorization")
        )
    }

    // MARK: Presigned URLs

    func testAPresignedUrlCarriesTheQueryParametersAvPlayerWillSend() throws {
        let url = try XCTUnwrap(SigV4.presignedURL(
            url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/a/ep.mp3")!,
            credentials: credentials, expiresIn: 900,
            now: Date(timeIntervalSince1970: 1_440_938_160)
        ))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = Set(query.map(\.name))

        XCTAssertEqual(names, [
            "X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date",
            "X-Amz-Expires", "X-Amz-SignedHeaders", "X-Amz-Signature",
        ])
        XCTAssertEqual(query.first { $0.name == "X-Amz-Expires" }?.value, "900")
        XCTAssertEqual(url.path, "/a/ep.mp3", "the key must survive intact")
    }

    /// The signature has to be last and unsigned-by-itself; a URL whose other parameters
    /// changed must not keep validating.
    func testAPresignedUrlChangesWithItsExpiry() throws {
        func url(expiresIn: Int) throws -> String {
            try XCTUnwrap(SigV4.presignedURL(
                url: URL(string: "https://bucket.s3.us-east-1.amazonaws.com/a")!,
                credentials: credentials, expiresIn: expiresIn,
                now: Date(timeIntervalSince1970: 1_440_938_160)
            )).absoluteString
        }

        XCTAssertNotEqual(try url(expiresIn: 900), try url(expiresIn: 3600))
    }
}

/// The list response is the only XML this app parses, and getting `CommonPrefixes` wrong
/// shows up as a folder that contains itself.
final class S3ListParserTests: XCTestCase {
    private func parse(_ xml: String) -> S3RestClient.ListResult {
        S3ListParser.parse(Data(xml.utf8))
    }

    func testObjectsAreReadWithTheirSizeHashAndDate() {
        let result = parse("""
        <ListBucketResult>
          <Contents>
            <Key>show/ep-01.mp3</Key>
            <LastModified>2026-09-19T12:00:00.000Z</LastModified>
            <ETag>&quot;abc123&quot;</ETag>
            <Size>4194304</Size>
          </Contents>
        </ListBucketResult>
        """)

        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects[0].key, "show/ep-01.mp3")
        XCTAssertEqual(result.objects[0].size, 4_194_304)
        XCTAssertEqual(result.objects[0].eTag, "abc123", "quotes stripped")
        XCTAssertNotNil(result.objects[0].lastModified)
    }

    /// `<Prefix>` appears twice in one response — once naming the request, once per
    /// subfolder. Reading both made the folder you were in appear inside itself.
    func testTheRequestsOwnPrefixIsNotReadAsASubfolder() {
        let result = parse("""
        <ListBucketResult>
          <Prefix>show/</Prefix>
          <CommonPrefixes><Prefix>show/2025/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>show/2026/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """)

        XCTAssertEqual(result.commonPrefixes, ["show/2025/", "show/2026/"])
    }

    func testPaginationTokenIsCarried() {
        let result = parse("""
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>tok123</NextContinuationToken>
        </ListBucketResult>
        """)

        XCTAssertEqual(result.nextContinuationToken, "tok123")
    }

    /// A missing backup is a normal answer, and the code is how the caller knows.
    func testAnErrorEnvelopeYieldsItsCode() {
        let parsed = S3ListParser.parseError(Data("""
        <Error><Code>NoSuchKey</Code><Message>The key does not exist.</Message></Error>
        """.utf8))

        XCTAssertEqual(parsed.code, "NoSuchKey")
        XCTAssertEqual(parsed.message, "The key does not exist.")
    }

    func testAnEmptyBucketParsesAsNothingRatherThanFailing() {
        let result = parse("<ListBucketResult><Name>bucket</Name></ListBucketResult>")

        XCTAssertTrue(result.objects.isEmpty)
        XCTAssertTrue(result.commonPrefixes.isEmpty)
        XCTAssertNil(result.nextContinuationToken)
    }
}
