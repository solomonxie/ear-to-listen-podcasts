import Foundation

/// The five S3 calls this app makes, over `URLSession`.
///
/// S3's REST API is plain HTTP with XML responses; the only hard part is the signature,
/// and that lives in `SigV4`. What this replaces brought Smithy, the AWS CRT, SwiftNIO and
/// a command-line argument parser along with it.
///
/// Deliberately not a general S3 client: no multipart, no streaming bodies, no retries
/// beyond what `URLSession` does. Add those when something needs them.
struct S3RestClient {
    let bucket: String
    let credentials: SigV4.Credentials

    /// Virtual-hosted style, except for bucket names containing a dot — those break TLS
    /// certificate matching on `*.s3.region.amazonaws.com`, so they go path-style.
    private var usesPathStyle: Bool { bucket.contains(".") }

    private var endpoint: URL {
        usesPathStyle
            ? URL(string: "https://s3.\(credentials.region).amazonaws.com")!
            : URL(string: "https://\(bucket).s3.\(credentials.region).amazonaws.com")!
    }

    private func url(key: String?, query: [(String, String)] = []) -> URL {
        var path = usesPathStyle ? "/\(bucket)" : ""
        if let key, !key.isEmpty {
            path += "/" + key.split(separator: "/").map { SigV4.encode(String($0)) }.joined(separator: "/")
        } else if path.isEmpty {
            path = "/"
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        if !query.isEmpty { components.percentEncodedQuery = SigV4.canonicalQuery(query) }
        return components.url!
    }

    // MARK: Operations

    struct ListResult {
        var objects: [S3Object] = []
        var commonPrefixes: [String] = []
        var nextContinuationToken: String?
    }

    struct S3Object {
        let key: String
        let size: Int64?
        let lastModified: Date?
        let eTag: String?
    }

    func listObjects(
        prefix: String?, delimiter: String? = nil, continuationToken: String? = nil, maxKeys: Int? = nil
    ) async throws -> ListResult {
        var query: [(String, String)] = [("list-type", "2")]
        if let prefix, !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        if let maxKeys { query.append(("max-keys", String(maxKeys))) }

        let data = try await send(method: "GET", url: url(key: nil, query: query))
        return S3ListParser.parse(data)
    }

    func headObject(key: String) async throws -> (size: Int64?, contentType: String?, lastModified: Date?, eTag: String?) {
        var request = URLRequest(url: url(key: key))
        request.httpMethod = "HEAD"
        SigV4.sign(&request, payload: Data(), credentials: credentials)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.malformedResponse }
        try check(http, body: Data())
        return (
            http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
            http.value(forHTTPHeaderField: "Content-Type"),
            http.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate),
            http.value(forHTTPHeaderField: "ETag")
        )
    }

    func getObject(key: String) async throws -> Data {
        try await send(method: "GET", url: url(key: key))
    }

    func putObject(key: String, data: Data, contentType: String) async throws {
        var request = URLRequest(url: url(key: key))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        SigV4.sign(&request, payload: data, credentials: credentials)
        // `upload(for:from:)` rather than setting `httpBody`: URLSession streams it and
        // doesn't hold a second copy of a backup archive in memory.
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw S3Error.malformedResponse }
        try check(http, body: body)
    }

    func presignedGetURL(key: String, expiresIn: Int = 3600) -> URL? {
        SigV4.presignedURL(url: url(key: key), credentials: credentials, expiresIn: expiresIn)
    }

    // MARK: Plumbing

    private func send(method: String, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        SigV4.sign(&request, payload: Data(), credentials: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.malformedResponse }
        try check(http, body: data)
        return data
    }

    /// S3 reports failures as 4xx/5xx with an XML body naming the code — `NoSuchKey`,
    /// `AccessDenied`, `SignatureDoesNotMatch`. Those names are the useful part, and what
    /// callers switch on, so they're carried rather than flattened into a status number.
    private func check(_ response: HTTPURLResponse, body: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let parsed = S3ListParser.parseError(body)
        throw S3Error.service(
            code: parsed.code ?? "HTTP \(response.statusCode)",
            message: parsed.message,
            status: response.statusCode
        )
    }

    private static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

enum S3Error: Error, LocalizedError {
    case service(code: String, message: String?, status: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .service(let code, let message, let status):
            return [code, message, "(HTTP \(status))"].compactMap { $0 }.joined(separator: ": ")
        case .malformedResponse:
            return "The storage service replied with something this app couldn't read."
        }
    }

    /// What callers branch on — a missing key is a normal answer for a backup that hasn't
    /// been written yet, not a failure.
    var code: String? {
        if case .service(let code, _, _) = self { return code }
        return nil
    }
}

/// Just enough XML for `ListObjectsV2` and S3's error envelope.
///
/// `XMLParser` is in Foundation and costs nothing. The responses are a flat list of known
/// element names, so this collects text by tag rather than building a tree.
enum S3ListParser {
    static func parse(_ data: Data) -> S3RestClient.ListResult {
        let delegate = ListDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    static func parseError(_ data: Data) -> (code: String?, message: String?) {
        let delegate = ListDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.errorCode, delegate.errorMessage)
    }

    private final class ListDelegate: NSObject, XMLParserDelegate {
        var result = S3RestClient.ListResult()
        var errorCode: String?
        var errorMessage: String?

        private var text = ""
        private var key: String?
        private var size: Int64?
        private var lastModified: Date?
        private var eTag: String?
        private var inContents = false
        /// `<Prefix>` appears twice in one response: once at the top naming what was
        /// asked for, and once inside each `<CommonPrefixes>` naming a subfolder. Without
        /// this the request's own prefix comes back as a folder inside itself.
        private var inCommonPrefixes = false

        /// Per instance, not `static`: a formatter isn't `Sendable`, and the delegate is
        /// already one-per-parse.
        private let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            text = ""
            if element == "Contents" {
                inContents = true
                key = nil; size = nil; lastModified = nil; eTag = nil
            }
            if element == "CommonPrefixes" { inCommonPrefixes = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "Key" where inContents: key = value
            case "Size" where inContents: size = Int64(value)
            case "ETag" where inContents: eTag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LastModified" where inContents:
                // S3 sends fractional seconds; the fallback covers a response that doesn't.
                lastModified = iso8601.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            case "Contents":
                inContents = false
                if let key {
                    result.objects.append(
                        .init(key: key, size: size, lastModified: lastModified, eTag: eTag)
                    )
                }
            case "Prefix" where inCommonPrefixes && !value.isEmpty:
                if !result.commonPrefixes.contains(value) { result.commonPrefixes.append(value) }
            case "CommonPrefixes": inCommonPrefixes = false
            case "NextContinuationToken": result.nextContinuationToken = value
            case "Code": errorCode = value
            case "Message": errorMessage = value
            default: break
            }
            text = ""
        }
    }
}
