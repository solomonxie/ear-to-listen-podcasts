import CryptoKit
import Foundation

/// Azure Blob Storage's "Shared Key" request signing, and the Service SAS query-string
/// signing behind a stream URL.
///
/// The same bargain `SigV4` makes for S3: two published, stable signing algorithms
/// against plain REST over `URLSession`, rather than an SDK for it. Both are HMAC-SHA256
/// over a string the service rebuilds from the request it received — so what matters is
/// the exact order and spelling of the fields below, which are Azure's.
///
/// Reference: *Authorize with Shared Key* and *Create a service SAS*, Azure Storage docs.
enum AzureSharedKey {
    struct Account: Sendable {
        let name: String
        /// Base64, as the portal shows it — it's the HMAC key's raw bytes, not a string.
        let key: String
    }

    static let apiVersion = "2021-08-06"

    private static func hmacBase64(key: String, message: String) -> String {
        guard let keyBytes = Data(base64Encoded: key) else { return "" }
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: keyBytes))
        return Data(code).base64EncodedString()
    }

    /// Adds `x-ms-date`, `x-ms-version` and the `Authorization` header.
    ///
    /// `contentLength` is passed in rather than read off the request: `Content-Length` is
    /// a reserved header URLSession sets itself, but it's a signed field, so what gets
    /// signed has to be the length URLSession is going to send.
    static func sign(
        _ request: inout URLRequest, account: Account, contentLength: Int = 0, now: Date = Date()
    ) {
        guard let url = request.url else { return }
        let date = rfc1123(now)
        request.setValue(date, forHTTPHeaderField: "x-ms-date")
        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")

        let headers = request.allHTTPHeaderFields ?? [:]
        func header(_ name: String) -> String {
            headers.first { $0.key.lowercased() == name }?.value ?? ""
        }

        let stringToSign = [
            request.httpMethod ?? "GET",
            header("content-encoding"),
            header("content-language"),
            contentLength == 0 ? "" : String(contentLength),
            header("content-md5"),
            header("content-type"),
            "", // Date — empty, x-ms-date is used instead
            header("if-modified-since"),
            header("if-match"),
            header("if-none-match"),
            header("if-unmodified-since"),
            header("range"),
        ].joined(separator: "\n")
            + "\n"
            + canonicalizedHeaders(headers)
            + canonicalizedResource(account: account.name, url: url)

        request.setValue(
            "SharedKey \(account.name):\(hmacBase64(key: account.key, message: stringToSign))",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// A URL that carries its own signature, for handing to something that won't set
    /// headers — `AVPlayer` streaming an episode. Read-only (`sp=r`) and blob-scoped
    /// (`sr=b`): the Azure equivalent of an S3 presigned GET.
    ///
    /// `container` and `blob` are the raw, unescaped names — that's how Azure defines the
    /// resource string, whatever the URL had to escape to get there.
    static func signedURL(
        url: URL, account: Account, container: String, blob: String,
        expiresIn: Int = 3600, now: Date = Date()
    ) -> URL? {
        let expiry = iso8601(now.addingTimeInterval(TimeInterval(expiresIn)))
        let stringToSign = [
            "r",                                              // signed permissions
            "",                                               // signed start
            expiry,                                           // signed expiry
            "/blob/\(account.name)/\(container)/\(blob)",     // canonicalized resource
            "",                                               // signed identifier
            "",                                               // signed IP
            "https",                                          // signed protocol
            apiVersion,                                       // signed version
            "b",                                              // signed resource (blob)
            "",                                               // signed snapshot time
            "",                                               // signed encryption scope
            "", "", "", "", "",                               // rscc, rscd, rsce, rscl, rsct
        ].joined(separator: "\n")

        let query: [(String, String)] = [
            ("sv", apiVersion),
            ("sr", "b"),
            ("sp", "r"),
            ("se", expiry),
            ("spr", "https"),
            ("sig", hmacBase64(key: account.key, message: stringToSign)),
        ]
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = query
            .map { "\(RFC3986.encode($0.0))=\(RFC3986.encode($0.1))" }
            .joined(separator: "&")
        return components?.url
    }

    /// Every `x-ms-` header, lowercased, sorted, one per line.
    private static func canonicalizedHeaders(_ headers: [String: String]) -> String {
        headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.0.hasPrefix("x-ms-") }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    /// `/account/container/blob`, then every query parameter — decoded, lowercased name,
    /// sorted — one per line.
    private static func canonicalizedResource(account: String, url: URL) -> String {
        var resource = "/\(account)\(url.path)"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var byName: [String: [String]] = [:]
        for item in items {
            byName[item.name.lowercased(), default: []].append(item.value ?? "")
        }
        for name in byName.keys.sorted() {
            resource += "\n\(name):\(byName[name]!.sorted().joined(separator: ","))"
        }
        return resource
    }

    static func rfc1123(_ date: Date) -> String { formatted(date, "EEE, dd MMM yyyy HH:mm:ss 'GMT'") }

    /// Second precision, no fraction — the expiry goes into the signature and the query
    /// string as one identical string.
    private static func iso8601(_ date: Date) -> String { formatted(date, "yyyy-MM-dd'T'HH:mm:ss'Z'") }

    static func parseRFC1123(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
