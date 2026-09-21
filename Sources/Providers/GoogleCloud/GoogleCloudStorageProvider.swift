import Foundation

/// Google Cloud Storage, over its JSON API.
///
/// The JSON API rather than the S3-compatible XML one, because the credential decides it:
/// a service account key is what Google actually hands out (`ServiceAccount`), and the
/// XML API only takes HMAC keys, which are off by default and a separate thing to go and
/// enable. Objects, prefixes and delimiters work the same either way.
struct GoogleCloudStorageProvider: CloudProvider {
    let type = CloudSourceKind.googleCloudStorage.providerType
    let rootFolder: String?

    private let account: GoogleServiceAccount
    private let bucket: String

    private static let apiBase = "https://storage.googleapis.com/storage/v1"
    private static let uploadBase = "https://storage.googleapis.com/upload/storage/v1"
    private static let pageSize = 1000

    init(config: CloudProviderConfig) throws {
        account = try GoogleServiceAccount(json: try config.required("serviceAccountJson"))
        bucket = try config.required("bucket")
        rootFolder = config.folder
    }

    // MARK: Listing

    private struct ObjectList: Decodable {
        struct Item: Decodable {
            let name: String
            let size: String?
            let contentType: String?
            let updated: String?
            let md5Hash: String?
        }
        var items: [Item]?
        var prefixes: [String]?
        var nextPageToken: String?
    }

    private func listObjects(prefix: String?, delimiter: String?, pageToken: String?, maxResults: Int = pageSize) async throws -> ObjectList {
        var query: [(String, String)] = [("maxResults", String(maxResults))]
        if let prefix, !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let pageToken { query.append(("pageToken", pageToken)) }
        return try await get(ObjectList.self, path: "/b/\(bucket)/o", query: query)
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        let timestamps = Timestamps()
        var files: [CloudFile] = []
        var pageToken: String?
        repeat {
            let page = try await listObjects(prefix: folderID ?? rootFolder, delimiter: nil, pageToken: pageToken)
            files += (page.items ?? []).map { cloudFile($0, timestamps) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let timestamps = Timestamps()
        let prefix = CloudFolderPath.normalized(folderID) ?? rootFolder ?? ""
        var folders: [String] = []
        var files: [CloudFile] = []
        var pageToken: String?
        repeat {
            let page = try await listObjects(prefix: prefix, delimiter: "/", pageToken: pageToken)
            for path in page.prefixes ?? [] where path != prefix {
                folders.append(String(path.dropLast(path.hasSuffix("/") ? 1 : 0)))
            }
            // A folder made through the console is a zero-byte object ending in "/" —
            // that's the folder itself, not a file in it.
            files += (page.items ?? [])
                .filter { $0.name != prefix && !$0.name.hasSuffix("/") }
                .map { cloudFile($0, timestamps) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (folders.sorted(), files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func cloudFile(_ item: ObjectList.Item, _ timestamps: Timestamps) -> CloudFile {
        CloudFile(
            id: item.name,
            name: (item.name as NSString).lastPathComponent,
            path: item.name,
            sizeBytes: item.size.flatMap(Int64.init),
            mimeType: item.contentType,
            modifiedAt: timestamps.date(item.updated),
            // Base64 MD5 rather than an ETag: it's what Google reports, and all this is
            // compared against is the same field from an earlier listing.
            contentHash: item.md5Hash
        )
    }

    // MARK: One object

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let item = try await get(ObjectList.Item.self, path: "/b/\(bucket)/o/\(RFC3986.encode(fileID))")
        return cloudFile(item, Timestamps())
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        guard let url = try GoogleSignedURL.get(account: account, bucket: bucket, object: fileID) else {
            throw GoogleCloudError.malformedResponse
        }
        return url
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await listObjects(prefix: rootFolder, delimiter: nil, pageToken: nil, maxResults: 1)
            return ConnectionTestResult(isSuccess: true, message: nil)
        } catch {
            return ConnectionTestResult(isSuccess: false, message: describeCloudError(error))
        }
    }

    var isWritable: Bool { true }

    /// A simple (non-resumable) media upload — a transcript sidecar or a library archive
    /// is small enough that a restartable upload would only be more moving parts.
    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        let name = try CloudWrite.checked(path)
        var request = URLRequest(url: url(
            base: Self.uploadBase, path: "/b/\(bucket)/o",
            query: [("uploadType", "media"), ("name", name)]
        ))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await GoogleAccessTokens.shared.token(for: account))", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        try check(response, body: body)
    }

    /// Google stamps objects in RFC 3339 with fractional seconds. One pair of formatters
    /// per listing, not per object: a formatter isn't `Sendable`, so it can't be a shared
    /// static, and building one for each of a few thousand files is work for nothing.
    private struct Timestamps {
        private let fractional: ISO8601DateFormatter
        private let whole = ISO8601DateFormatter()

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            return fractional.date(from: text) ?? whole.date(from: text)
        }
    }

    // MARK: Plumbing

    private func url(base: String, path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(RFC3986.encode($0.0))=\(RFC3986.encode($0.1))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    private func get<Body: Decodable>(
        _ type: Body.Type, path: String, query: [(String, String)] = []
    ) async throws -> Body {
        var request = URLRequest(url: url(base: Self.apiBase, path: path, query: query))
        request.setValue("Bearer \(try await GoogleAccessTokens.shared.token(for: account))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, body: data)
        guard let decoded = try? JSONDecoder().decode(Body.self, from: data) else {
            throw GoogleCloudError.malformedResponse
        }
        return decoded
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw GoogleCloudError.malformedResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw GoogleCloudError.service(
            message: GoogleAPIError.message(in: body) ?? "Google Cloud Storage refused the request",
            status: http.statusCode
        )
    }
}
