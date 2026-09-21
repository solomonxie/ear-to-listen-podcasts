import Foundation

/// The fields of a bucket connection — bucket, folder path, key, secret, region — read
/// out of a pasted block of text.
///
/// Credentials arrive as a lump — a note, a chat message, a chunk of an AWS CLI
/// credentials file — and retyping a 40-character secret on a phone keyboard is where
/// this goes wrong. So the parser is deliberately forgiving rather than strict about one
/// format: `:` or `=`, any capitalisation, and keys written as `access_key_id`,
/// `accessKeyId`, `Access Key ID` or `aws_access_key_id` all land in the same place.
///
/// Every cloud's own spelling of the same two halves lands there too — Tencent's
/// `SecretId`/`SecretKey`, Alibaba's `AccessKey Secret`, Azure's `AccountName`/`AccountKey`
/// — because which cloud this text came from is already the picker's answer, not
/// something to make the listener restate in the right vocabulary.
struct BucketConnectionDraft: Equatable {
    var bucket: String?
    var keyPrefix: String?
    var accessKeyId: String?
    var secretAccessKey: String?
    var region: String?

    var isEmpty: Bool {
        bucket == nil && keyPrefix == nil && accessKeyId == nil && secretAccessKey == nil && region == nil
    }

    static func parse(_ text: String) -> BucketConnectionDraft {
        var draft = BucketConnectionDraft()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("[") else { continue }
            // First separator only: a secret can itself contain '=' or '/'.
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let value = cleanedValue(String(line[line.index(after: separator)...]))
            guard !value.isEmpty else { continue }

            switch normalizedKey(String(line[..<separator])) {
            case "bucket", "bucketname", "s3bucket", "container", "containername": draft.bucket = value
            // Normalized on the way in, so a pasted `podcasts` fills the field as
            // `podcasts/` — the only form that addresses a folder rather than a name
            // fragment.
            case "prefix", "keyprefix", "folder", "path", "folderpath": draft.keyPrefix = CloudFolderPath.normalized(value)
            case "accesskeyid", "awsaccesskeyid", "accesskey", "secretid", "accountname":
                draft.accessKeyId = value
            case "secretaccesskey", "awssecretaccesskey", "secretkey", "accesskeysecret", "accountkey":
                draft.secretAccessKey = value
            case "region", "awsregion", "regionid": draft.region = value
            default: break
            }
        }
        return draft
    }

    /// Collapses `- Access Key ID`, `access_key_id` and `accessKeyId` to one spelling.
    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func cleanedValue(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespaces)
        if cleaned.hasSuffix(",") { cleaned.removeLast() }
        if cleaned.count >= 2, let first = cleaned.first, first == cleaned.last, first == "\"" || first == "'" {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
