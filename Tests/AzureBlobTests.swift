import XCTest
@testable import EarToListen

/// The two signatures Azure checks, against values computed independently of this code.
/// A signer can only be wrong in ways that look fine from the inside — every field is
/// optional-looking, and the service's only answer is 403.
final class AzureBlobTests: XCTestCase {
    private let account = AzureSharedKey.Account(
        name: "myaccount", key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
    )
    private let moment = Date(timeIntervalSince1970: 1_700_000_000)

    func testSharedKeySignsAListing() {
        let url = URL(string: "https://myaccount.blob.core.windows.net/podcasts?restype=container&comp=list&maxresults=1&prefix=shows%2F")!
        var request = URLRequest(url: url)
        AzureSharedKey.sign(&request, account: account, now: moment)

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-date"), "Tue, 14 Nov 2023 22:13:20 GMT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-version"), "2021-08-06")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "SharedKey myaccount:L0PGn9fJyM7TATXmi6D5OLgBHdqCsVMaB4S2SkNKuFQ="
        )
    }

    /// The SAS is signed over the *unescaped* blob name, whatever the URL had to escape.
    func testStreamURLCarriesAReadOnlySAS() throws {
        let url = URL(string: "https://myaccount.blob.core.windows.net/podcasts/shows/ep%201.mp3")!
        let signed = try XCTUnwrap(AzureSharedKey.signedURL(
            url: url, account: account, container: "podcasts", blob: "shows/ep 1.mp3", now: moment
        ))
        let items = try XCTUnwrap(URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(byName["sp"], "r")
        XCTAssertEqual(byName["sr"], "b")
        XCTAssertEqual(byName["se"], "2023-11-14T23:13:20Z")
        XCTAssertEqual(byName["sig"], "J50csXT3e9fN8ooJlEZQJayBfeCcQ8LJqct44RU/XrI=")
        XCTAssertEqual(signed.path, "/podcasts/shows/ep 1.mp3")
    }

    func testConnectionStringSplitsIntoAccountAndKey() {
        let parsed = AzureConnectionString.parse(
            "DefaultEndpointsProtocol=https;AccountName=myaccount;AccountKey=abc/def+ghi==;EndpointSuffix=core.windows.net"
        )
        XCTAssertEqual(parsed?.accountName, "myaccount")
        // The key is base64 and ends in padding — splitting on every "=" would truncate it.
        XCTAssertEqual(parsed?.accountKey, "abc/def+ghi==")
    }

    func testSomethingThatIsntAConnectionStringIsRefused() {
        XCTAssertNil(AzureConnectionString.parse("AccountName=myaccount"))
        XCTAssertNil(AzureConnectionString.parse("just a note"))
    }

    func testListBlobsSeparatesFoldersFromBlobs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults ContainerName="podcasts">
          <Blobs>
            <BlobPrefix><Name>shows/season1/</Name></BlobPrefix>
            <Blob>
              <Name>shows/ep1.mp3</Name>
              <Properties>
                <Last-Modified>Tue, 14 Nov 2023 22:13:20 GMT</Last-Modified>
                <Etag>"0x8DB123"</Etag>
                <Content-Length>1234</Content-Length>
                <Content-Type>audio/mpeg</Content-Type>
              </Properties>
            </Blob>
          </Blobs>
          <NextMarker />
        </EnumerationResults>
        """
        let listing = BlobListXML.parse(Data(xml.utf8))

        XCTAssertEqual(listing.prefixes, ["shows/season1/"])
        XCTAssertEqual(listing.blobs.map(\.name), ["shows/ep1.mp3"])
        XCTAssertEqual(listing.blobs.first?.contentLength, 1234)
        XCTAssertEqual(listing.blobs.first?.contentType, "audio/mpeg")
        XCTAssertEqual(listing.blobs.first?.eTag, "0x8DB123")
        XCTAssertEqual(listing.blobs.first?.lastModified, Date(timeIntervalSince1970: 1_700_000_000))
        // An empty <NextMarker/> is how the last page says "no more" — reading it as a
        // marker would page forever.
        XCTAssertNil(listing.nextMarker)
    }

    func testAnErrorBodyKeepsTheCodeAzureSent() {
        let parsed = StorageErrorXML.parse(Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <Error><Code>AuthenticationFailed</Code><Message>Server failed to authenticate.</Message></Error>
        """.utf8))
        XCTAssertEqual(parsed.code, "AuthenticationFailed")
        XCTAssertEqual(parsed.message, "Server failed to authenticate.")
    }
}
