import Foundation

/// Percent-encoding as every one of these storage APIs defines it: everything that isn't
/// `A-Za-z0-9-_.~` is escaped, uppercase hex.
///
/// Not `addingPercentEncoding`'s idea of "allowed" — that leaves `+`, `=`, `&` and others
/// alone, and a signature computed over a differently-escaped string is simply wrong.
enum RFC3986 {
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

    /// Each path segment escaped, the separators left alone.
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }
}
