import Foundation

/// A connection's folder inside its bucket. Only whole folders are addressable: a bare key
/// fragment (`pod`) would quietly also match `podcasts-old/`, so what's stored always ends
/// in a slash — added here when it's left off rather than asked for again.
///
/// Every cloud this app talks to files objects by flat key with `/` as the only hint of a
/// hierarchy — S3, COS, OSS, Azure blobs, Google objects alike — so one normalizer serves
/// all of them.
enum CloudFolderPath {
    /// `nil` for "the whole bucket". Leading slashes go (object keys have no root),
    /// repeated ones collapse, and the trailing one is guaranteed.
    static func normalized(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        let collapsed = path.split(separator: "/").joined(separator: "/")
        return collapsed.isEmpty ? nil : collapsed + "/"
    }
}
