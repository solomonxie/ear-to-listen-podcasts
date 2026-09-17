import Foundation

/// A connection's folder inside its bucket. Only whole folders are addressable: a bare key
/// fragment (`pod`) would quietly also match `podcasts-old/`, so what's stored always ends
/// in a slash — added here when it's left off rather than asked for again.
enum S3FolderPath {
    /// `nil` for "the whole bucket". Leading slashes go (S3 keys have no root), repeated
    /// ones collapse, and the trailing one is guaranteed.
    static func normalized(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        let collapsed = path.split(separator: "/").joined(separator: "/")
        return collapsed.isEmpty ? nil : collapsed + "/"
    }
}
