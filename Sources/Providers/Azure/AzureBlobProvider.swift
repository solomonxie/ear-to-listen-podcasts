import Foundation

/// Azure Blob Storage.
///
/// Containers instead of buckets, blobs instead of keys, Shared Key instead of SigV4 —
/// but the same flat, prefix-and-delimiter browsing model underneath, so everything above
/// this file treats it exactly like a bucket.
struct AzureBlobProvider: CloudProvider {
    let type = CloudSourceKind.azureBlob.providerType
    let rootFolder: String?

    private let account: AzureSharedKey.Account
    private let container: String

    /// 5,000 is the service's own maximum per page; the listing loop pages regardless, so
    /// this only decides how many round trips a big folder takes.
    private static let pageSize = 5000

    init(config: CloudProviderConfig) throws {
        account = AzureSharedKey.Account(
            name: try config.required("accessKeyId"), key: try config.required("secretAccessKey")
        )
        container = try config.required("bucket")
        rootFolder = config.folder
    }

    private var host: String { "\(account.name).blob.core.windows.net" }

    private func url(blob: String?, query: [(String, String)] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = "/\(RFC3986.encode(container))"
            + (blob.map { "/" + RFC3986.encodePath($0) } ?? "")
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(RFC3986.encode($0.0))=\(RFC3986.encode($0.1))" }
                .joined(separator: "&")
        }
        return components.url!
    }

    // MARK: Listing

    /// One page. `delimiter` nil walks the whole subtree, which is what a sync wants;
    /// `"/"` stops at one level, which is what browsing wants.
    private func listBlobs(
        prefix: String?, delimiter: String?, marker: String?, maxResults: Int = pageSize
    ) async throws -> BlobListXML.Listing {
        var query: [(String, String)] = [
            ("restype", "container"), ("comp", "list"), ("maxresults", String(maxResults)),
        ]
        if let prefix, !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let marker, !marker.isEmpty { query.append(("marker", marker)) }

        var request = URLRequest(url: url(blob: nil, query: query))
        AzureSharedKey.sign(&request, account: account)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, body: data)
        return BlobListXML.parse(data)
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        var marker: String?
        repeat {
            let page = try await listBlobs(prefix: folderID ?? rootFolder, delimiter: nil, marker: marker)
            files += page.blobs.map(cloudFile)
            marker = page.nextMarker
        } while marker != nil
        return files
    }

    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let prefix = CloudFolderPath.normalized(folderID) ?? rootFolder ?? ""
        var folders: [String] = []
        var files: [CloudFile] = []
        var marker: String?
        repeat {
            let page = try await listBlobs(prefix: prefix, delimiter: "/", marker: marker)
            for path in page.prefixes where path != prefix {
                folders.append(String(path.dropLast(path.hasSuffix("/") ? 1 : 0)))
            }
            // A folder made by a tool that emulates them is a zero-byte blob ending in
            // "/" — that's the folder itself, not a file in it.
            files += page.blobs.filter { $0.name != prefix && !$0.name.hasSuffix("/") }.map(cloudFile)
            marker = page.nextMarker
        } while marker != nil
        return (folders.sorted(), files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    private func cloudFile(_ blob: BlobListXML.Blob) -> CloudFile {
        CloudFile(
            id: blob.name,
            name: (blob.name as NSString).lastPathComponent,
            path: blob.name,
            sizeBytes: blob.contentLength,
            mimeType: blob.contentType,
            modifiedAt: blob.lastModified,
            contentHash: blob.eTag
        )
    }

    // MARK: One blob

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        var request = URLRequest(url: url(blob: fileID))
        request.httpMethod = "HEAD"
        AzureSharedKey.sign(&request, account: account)
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response, body: Data())
        let http = response as? HTTPURLResponse
        return CloudFile(
            id: fileID,
            name: (fileID as NSString).lastPathComponent,
            path: fileID,
            sizeBytes: http?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
            mimeType: http?.value(forHTTPHeaderField: "Content-Type"),
            modifiedAt: http?.value(forHTTPHeaderField: "Last-Modified").flatMap(AzureSharedKey.parseRFC1123),
            contentHash: http?.value(forHTTPHeaderField: "ETag")?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        )
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        guard let signed = AzureSharedKey.signedURL(
            url: url(blob: fileID), account: account, container: container, blob: fileID
        ) else {
            throw AzureError.malformedResponse
        }
        return signed
    }

    func testConnection() async -> ConnectionTestResult {
        do {
            _ = try await listBlobs(prefix: rootFolder, delimiter: nil, marker: nil, maxResults: 1)
            return ConnectionTestResult(isSuccess: true, message: nil)
        } catch {
            return ConnectionTestResult(isSuccess: false, message: describeCloudError(error))
        }
    }

    var isWritable: Bool { true }

    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        let blob = try CloudWrite.checked(path)
        var request = URLRequest(url: url(blob: blob))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        AzureSharedKey.sign(&request, account: account, contentLength: data.count)
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        try check(response, body: body)
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AzureError.malformedResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        // Azure's error bodies are the same `<Error><Code>…` envelope S3 uses.
        let parsed = StorageErrorXML.parse(body)
        throw AzureError.service(
            code: parsed.code ?? "HTTP \(http.statusCode)", message: parsed.message, status: http.statusCode
        )
    }
}

enum AzureError: Error, LocalizedError {
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
}

/// Just enough XML for `List Blobs`: the blobs on this page, the folders beside them, and
/// the marker that asks for the next page.
enum BlobListXML {
    struct Blob {
        var name: String
        var contentLength: Int64?
        var contentType: String?
        var lastModified: Date?
        var eTag: String?
    }

    struct Listing {
        var blobs: [Blob] = []
        var prefixes: [String] = []
        var nextMarker: String?
    }

    static func parse(_ data: Data) -> Listing {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.listing
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var listing = Listing()

        private var text = ""
        private var blob: Blob?
        /// `<Name>` is used by both a blob and a folder, so which container it's in is the
        /// only thing that tells them apart.
        private var inBlobPrefix = false

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            text = ""
            switch element {
            case "Blob": blob = Blob(name: "")
            case "BlobPrefix": inBlobPrefix = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "Name" where inBlobPrefix:
                if !value.isEmpty, !listing.prefixes.contains(value) { listing.prefixes.append(value) }
            case "Name": blob?.name = value
            case "Content-Length": blob?.contentLength = Int64(value)
            case "Content-Type": blob?.contentType = value
            case "Last-Modified": blob?.lastModified = AzureSharedKey.parseRFC1123(value)
            case "Etag", "ETag": blob?.eTag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "Blob":
                if let blob, !blob.name.isEmpty { listing.blobs.append(blob) }
                blob = nil
            case "BlobPrefix": inBlobPrefix = false
            // Azure sends an empty `<NextMarker/>` on the last page, which is how it says
            // "no more" — an empty string would keep the loop going forever.
            case "NextMarker": listing.nextMarker = value.isEmpty ? nil : value
            default: break
            }
            text = ""
        }
    }
}
