import CryptoKit
import Foundation

/// AWS Signature Version 4, for the handful of S3 calls this app makes.
///
/// The official SDK brings ~150 MB of build output — Smithy, the CRT, SwiftNIO, an
/// argument parser — to sign five requests. The signing itself is a published, stable
/// algorithm that fits on a page, and the requests are plain REST over `URLSession`. This
/// is the same bargain `OpenAIChatClient` already makes: one endpoint isn't worth a
/// dependency.
///
/// Reference: *Signature Version 4 signing process*, AWS General Reference. The steps and
/// their names below are that document's.
enum SigV4 {
    struct Credentials {
        let accessKeyID: String
        let secretAccessKey: String
        let region: String
        var service = "s3"
    }

    /// Everything that isn't `A-Za-z0-9-_.~` is percent-encoded, uppercase hex. Not
    /// `addingPercentEncoding`'s idea of "allowed" — that leaves `+`, `=`, `&` and others
    /// alone, and a signature computed over a differently-escaped string is simply wrong.
    static func encode(_ text: String, encodeSlash: Bool = true) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        var out = ""
        for byte in Array(text.utf8) {
            let scalar = Character(UnicodeScalar(byte))
            if unreserved.contains(scalar) {
                out.append(scalar)
            } else if scalar == "/" && !encodeSlash {
                out.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// `AWS4` + secret, then date → region → service → `aws4_request`. Deriving it per
    /// request is cheap and avoids caching a key that's only valid for one day.
    private static func signingKey(_ credentials: Credentials, date: String) -> Data {
        var key = Data("AWS4\(credentials.secretAccessKey)".utf8)
        for step in [date, credentials.region, credentials.service, "aws4_request"] {
            key = hmac(key, step)
        }
        return key
    }

    static func amzDate(_ date: Date) -> String { formatted(date, "yyyyMMdd'T'HHmmss'Z'") }
    static func dateStamp(_ date: Date) -> String { formatted(date, "yyyyMMdd") }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Query string in the canonical form: sorted by encoded name, every name and value
    /// encoded, `=` even for empty values.
    static func canonicalQuery(_ items: [(String, String)]) -> String {
        // Spelled out rather than chained: the tuple-typed chain took the type checker
        // past its budget and failed the build outright.
        var encoded: [(name: String, value: String)] = []
        for item in items {
            encoded.append((encode(item.0), encode(item.1)))
        }
        encoded.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }
        var parts: [String] = []
        for pair in encoded {
            parts.append(pair.name + "=" + pair.value)
        }
        return parts.joined(separator: "&")
    }

    /// Signs a request with an `Authorization` header — the form used for everything that
    /// isn't a URL handed to `AVPlayer`.
    static func sign(
        _ request: inout URLRequest, payload: Data, credentials: Credentials, now: Date = Date()
    ) {
        guard let url = request.url, let host = url.host else { return }
        let date = amzDate(now)
        let stamp = dateStamp(now)
        let payloadHash = sha256Hex(payload)

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(date, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Only the headers actually signed, lowercased and sorted — the server recomputes
        // from exactly this list.
        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", date),
        ]
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            headers.append(("content-type", contentType))
        }
        headers.sort { $0.0 < $1.0 }

        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let query = url.query ?? ""

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            encode(url.path.isEmpty ? "/" : url.path, encodeSlash: false),
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(stamp)/\(credentials.region)/\(credentials.service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", date, scope, sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = hmac(signingKey(credentials, date: stamp), stringToSign)
            .map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// A URL that carries its own signature, for handing to something that won't set
    /// headers — `AVPlayer` streaming an episode, or a plain `URLSession.data(from:)`.
    ///
    /// The payload is `UNSIGNED-PAYLOAD`: the body isn't known when the URL is minted, and
    /// for a GET there isn't one.
    static func presignedURL(
        method: String = "GET", url: URL, credentials: Credentials,
        expiresIn: Int = 3600, now: Date = Date()
    ) -> URL? {
        guard let host = url.host else { return nil }
        let date = amzDate(now)
        let stamp = dateStamp(now)
        let scope = "\(stamp)/\(credentials.region)/\(credentials.service)/aws4_request"

        let query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
            ("X-Amz-Date", date),
            ("X-Amz-Expires", String(expiresIn)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQueryString = canonicalQuery(query)

        let canonicalRequest = [
            method,
            encode(url.path.isEmpty ? "/" : url.path, encodeSlash: false),
            canonicalQueryString,
            "host:\(host)\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256", date, scope, sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = hmac(signingKey(credentials, date: stamp), stringToSign)
            .map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = canonicalQueryString + "&X-Amz-Signature=\(signature)"
        return components?.url
    }
}
