import CryptoKit
import Foundation
import Security

/// The credential Google hands out for a program: the service account JSON key, pasted in
/// whole. No browser sign-in, nothing to refresh by hand — the same shape of credential
/// as an S3 key pair, just longer and RSA.
///
/// Two things are signed with the private key in it, and they're signed differently:
///
/// - **API calls** carry a short-lived OAuth2 access token, got by signing a JWT and
///   exchanging it (RFC 7523's JWT Bearer flow — server to server, no consent screen).
/// - **Stream URLs** are `GOOG4-RSA-SHA256` V4 signed URLs, signed directly. That scheme
///   is AWS's SigV4 with RSA swapped in for HMAC, which is why the pieces below are built
///   with `SigV4`'s own helpers.
struct GoogleServiceAccount: Sendable {
    let clientEmail: String
    let tokenURI: String
    private let privateKeyPEM: String

    private struct KeyFile: Decodable {
        let client_email: String
        let private_key: String
        let token_uri: String?
    }

    init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let file = try? JSONDecoder().decode(KeyFile.self, from: data) else {
            throw GoogleCloudError.badServiceAccount
        }
        clientEmail = file.client_email
        privateKeyPEM = file.private_key
        tokenURI = file.token_uri ?? "https://oauth2.googleapis.com/token"
        guard !clientEmail.isEmpty, !privateKeyPEM.isEmpty else { throw GoogleCloudError.badServiceAccount }
    }

    func sign(_ message: String) throws -> Data {
        let key = try RSAPrivateKey.from(pem: privateKeyPEM)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, &error
        ) else {
            throw error?.takeRetainedValue() ?? GoogleCloudError.badServiceAccount
        }
        return signature as Data
    }
}

enum GoogleCloudError: Error, LocalizedError {
    case badServiceAccount
    case tokenExchangeFailed(String)
    case service(message: String, status: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .badServiceAccount:
            return "That doesn't look like a service account key — paste the whole JSON file, including its private_key."
        case .tokenExchangeFailed(let message):
            return "Google wouldn't issue a token for this key: \(message)"
        case .service(let message, let status):
            return "\(message) (HTTP \(status))"
        case .malformedResponse:
            return "The storage service replied with something this app couldn't read."
        }
    }
}

/// A PEM private key as `Security` wants it.
///
/// Google writes the key as PKCS#8 (`BEGIN PRIVATE KEY`), and `SecKeyCreateWithData` only
/// takes PKCS#1 (`BEGIN RSA PRIVATE KEY`) — so the PKCS#8 wrapper, which is three DER
/// elements deep and carries nothing this app needs, is unwrapped here.
enum RSAPrivateKey {
    static func from(pem: String) throws -> SecKey {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: body) else { throw GoogleCloudError.badServiceAccount }

        let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try unwrapPKCS8(der)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            pkcs1 as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary,
            &error
        ) else {
            throw error?.takeRetainedValue() ?? GoogleCloudError.badServiceAccount
        }
        return key
    }

    /// `SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING privateKey }` — the
    /// octet string is the PKCS#1 key, and the rest says only "this is RSA", which we knew.
    private static func unwrapPKCS8(_ der: Data) throws -> Data {
        var cursor = der.startIndex
        guard let outer = try element(in: der, at: &cursor), outer.tag == 0x30 else {
            throw GoogleCloudError.badServiceAccount
        }
        var inner = outer.range.lowerBound
        guard try element(in: der, at: &inner) != nil,          // version
              try element(in: der, at: &inner) != nil,          // algorithm identifier
              let key = try element(in: der, at: &inner), key.tag == 0x04 else {
            throw GoogleCloudError.badServiceAccount
        }
        return der[key.range]
    }

    /// One tag-length-value at `cursor`, leaving `cursor` on the next one.
    private static func element(
        in der: Data, at cursor: inout Data.Index
    ) throws -> (tag: UInt8, range: Range<Data.Index>)? {
        guard cursor < der.endIndex else { return nil }
        let tag = der[cursor]
        var index = der.index(after: cursor)
        guard index < der.endIndex else { throw GoogleCloudError.badServiceAccount }

        var length = Int(der[index])
        index = der.index(after: index)
        // High bit set means "the next n bytes are the length", big-endian.
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount > 0, byteCount <= 4, der.index(index, offsetBy: byteCount) <= der.endIndex else {
                throw GoogleCloudError.badServiceAccount
            }
            length = 0
            for _ in 0..<byteCount {
                length = length << 8 | Int(der[index])
                index = der.index(after: index)
            }
        }
        let end = der.index(index, offsetBy: length)
        guard end <= der.endIndex else { throw GoogleCloudError.badServiceAccount }
        cursor = end
        return (tag, index..<end)
    }
}

/// One access token per service account, refreshed a minute before it actually expires.
/// An actor because every call needs one: two requests starting together should wait on
/// one exchange, not race two.
actor GoogleAccessTokens {
    static let shared = GoogleAccessTokens()

    private var cached: [String: (token: String, expiresAt: Date)] = [:]

    func token(for account: GoogleServiceAccount) async throws -> String {
        if let entry = cached[account.clientEmail], entry.expiresAt > Date() { return entry.token }
        let fresh = try await exchange(account)
        cached[account.clientEmail] = fresh
        return fresh.token
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
    }

    private func exchange(_ account: GoogleServiceAccount) async throws -> (token: String, expiresAt: Date) {
        let now = Date()
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/devstorage.read_write",
            "aud": account.tokenURI,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.timeIntervalSince1970) + 3600,
        ]
        let unsigned = try [
            base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)),
            base64URL(JSONSerialization.data(withJSONObject: claims)),
        ].joined(separator: ".")
        let jwt = unsigned + "." + base64URL(try account.sign(unsigned))

        var request = URLRequest(url: URL(string: account.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            ("grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=" + jwt).utf8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleCloudError.tokenExchangeFailed(
                GoogleAPIError.message(in: data) ?? String(data: data, encoding: .utf8) ?? "no reply"
            )
        }
        return (token.access_token, now.addingTimeInterval(token.expires_in - 60))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `GOOG4-RSA-SHA256` — AWS's query-string presigning, RSA-signed with the service
/// account's private key instead of an HMAC secret, and always scoped to the pseudo-region
/// `auto`. GET only: it exists so `AVPlayer` can stream an episode without a header.
enum GoogleSignedURL {
    static func get(
        account: GoogleServiceAccount, bucket: String, object: String,
        expiresIn: Int = 3600, now: Date = Date()
    ) throws -> URL? {
        let host = "storage.googleapis.com"
        let date = SigV4.amzDate(now)
        let scope = "\(SigV4.dateStamp(now))/auto/storage/goog4_request"
        let path = "/" + RFC3986.encodePath("\(bucket)/\(object)")

        let canonicalQuery = SigV4.canonicalQuery([
            ("X-Goog-Algorithm", "GOOG4-RSA-SHA256"),
            ("X-Goog-Credential", "\(account.clientEmail)/\(scope)"),
            ("X-Goog-Date", date),
            ("X-Goog-Expires", String(expiresIn)),
            ("X-Goog-SignedHeaders", "host"),
        ])
        let canonicalRequest = [
            "GET", path, canonicalQuery, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")
        let stringToSign = [
            "GOOG4-RSA-SHA256", date, scope, SigV4.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = try account.sign(stringToSign).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.percentEncodedQuery = canonicalQuery + "&X-Goog-Signature=\(signature)"
        return components.url
    }
}

/// Google's JSON errors: `{"error": {"code": 403, "message": "…"}}`. The message is the
/// useful half — "does not have storage.objects.list access" names the missing permission.
enum GoogleAPIError {
    static func message(in data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String }
            let error: Inner
        }
        return try? JSONDecoder().decode(Envelope.self, from: data).error.message
    }
}
