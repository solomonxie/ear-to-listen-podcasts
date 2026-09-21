import Foundation

/// The one string Azure's portal and SDKs hand out:
/// `DefaultEndpointsProtocol=https;AccountName=…;AccountKey=…;EndpointSuffix=core.windows.net`
///
/// Worth parsing because it's what's on the clipboard — the alternative is asking someone
/// to pick the account name and an 88-character key out of it by hand on a phone.
enum AzureConnectionString {
    /// `nil` unless both halves are there — a string missing either isn't a connection.
    static func parse(_ text: String) -> (accountName: String, accountKey: String)? {
        var fields: [String: String] = [:]
        for segment in text.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            // First `=` only: an account key is base64 and ends in padding.
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<separator].trimmingCharacters(in: .whitespaces)
            fields[name.lowercased()] = String(segment[segment.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["accountname"], !name.isEmpty,
              let key = fields["accountkey"], !key.isEmpty else { return nil }
        return (name, key)
    }
}
