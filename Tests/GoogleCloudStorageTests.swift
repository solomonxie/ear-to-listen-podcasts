import Security
import XCTest
@testable import EarToListen

/// The Google half is all key handling: the credential arrives as a PKCS#8 PEM inside a
/// JSON file, and `Security` only takes PKCS#1 — so these generate a real key, wrap it the
/// way Google's console does, and check a signature actually comes out the other end.
final class GoogleCloudStorageTests: XCTestCase {
    private func generatedKeyPEM(pkcs8: Bool = true) throws -> String {
        var error: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateRandomKey(
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error
        ))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, &error) as Data?)
        let der = pkcs8 ? Self.wrapInPKCS8(pkcs1) : pkcs1
        let label = pkcs8 ? "PRIVATE KEY" : "RSA PRIVATE KEY"
        return "-----BEGIN \(label)-----\n\(der.base64EncodedString())\n-----END \(label)-----\n"
    }

    /// `SEQUENCE { INTEGER 0, SEQUENCE { OID rsaEncryption, NULL }, OCTET STRING key }` —
    /// the wrapper `RSAPrivateKey` has to peel back off.
    private static func wrapInPKCS8(_ pkcs1: Data) -> Data {
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let body = Data([0x02, 0x01, 0x00]) + algorithm + tagged(0x04, pkcs1)
        return tagged(0x30, body)
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        var out = Data([tag])
        switch body.count {
        case ..<0x80: out.append(UInt8(body.count))
        case ..<0x100: out += Data([0x81, UInt8(body.count)])
        default: out += Data([0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
        }
        return out + body
    }

    private func serviceAccountJSON(privateKey: String) throws -> String {
        let fields: [String: Any] = [
            "type": "service_account",
            "client_email": "podcasts@example.iam.gserviceaccount.com",
            "private_key": privateKey,
        ]
        return String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
    }

    func testAPastedKeyThatIsntAServiceAccountIsRefused() {
        XCTAssertThrowsError(try GoogleServiceAccount(json: "not json at all"))
        XCTAssertThrowsError(try GoogleServiceAccount(json: #"{"client_email": "a@b.com"}"#))
    }

    func testAServiceAccountSignsWithItsPKCS8Key() throws {
        let account = try GoogleServiceAccount(json: serviceAccountJSON(privateKey: generatedKeyPEM()))
        XCTAssertEqual(account.clientEmail, "podcasts@example.iam.gserviceaccount.com")
        // 2048-bit RSA, so 256 bytes of signature whatever the message.
        XCTAssertEqual(try account.sign("anything").count, 256)
    }

    /// Some tools hand out the PKCS#1 form instead; it needs no unwrapping and must still work.
    func testAPlainRSAKeyWorksToo() throws {
        let account = try GoogleServiceAccount(json: serviceAccountJSON(privateKey: generatedKeyPEM(pkcs8: false)))
        XCTAssertEqual(try account.sign("anything").count, 256)
    }

    func testStreamURLIsAV4SignedGet() throws {
        let account = try GoogleServiceAccount(json: serviceAccountJSON(privateKey: generatedKeyPEM()))
        let url = try XCTUnwrap(try GoogleSignedURL.get(
            account: account, bucket: "podcasts", object: "shows/ep 1.mp3",
            expiresIn: 900, now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "storage.googleapis.com")
        XCTAssertEqual(url.path, "/podcasts/shows/ep 1.mp3")
        XCTAssertEqual(byName["X-Goog-Algorithm"], "GOOG4-RSA-SHA256")
        XCTAssertEqual(
            byName["X-Goog-Credential"],
            "podcasts@example.iam.gserviceaccount.com/20231114/auto/storage/goog4_request"
        )
        XCTAssertEqual(byName["X-Goog-Date"], "20231114T221320Z")
        XCTAssertEqual(byName["X-Goog-Expires"], "900")
        XCTAssertEqual(byName["X-Goog-Signature"]?.count, 512)
    }

    func testTheProviderNeedsABucketAndAKey() {
        let config = CloudProviderConfig(
            id: "test", type: CloudSourceKind.googleCloudStorage.providerType, label: "Test",
            settings: ["bucket": "podcasts"]
        )
        XCTAssertThrowsError(try GoogleCloudStorageProvider(config: config)) { error in
            guard case CloudProviderError.missingSetting(let key) = error else {
                return XCTFail("expected missingSetting, got \(error)")
            }
            XCTAssertEqual(key, "serviceAccountJson")
        }
    }
}
