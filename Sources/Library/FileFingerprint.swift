import Foundation

/// What makes two files the same episode when their names don't say so — the same
/// recording copied into a second bucket, or sitting in one bucket under two names.
///
/// **Not the provider's hash.** Every cloud calls something an ETag and means something
/// different by it: S3's is the file's MD5 only when it was uploaded in one part (a
/// multipart upload hashes the parts instead, so the answer depends on how it was put
/// there), Google's is base64 where S3's is hex, Azure's isn't a content hash at all but
/// a version tag, and a folder on this device offers nothing. Two copies of one episode
/// in two clouds would therefore never agree — which is exactly the case this exists for.
///
/// **Bytes and length, both already known.** The size comes off the listing every sync
/// does; the duration comes off the tags read once at import. They mean the same thing
/// at every provider. A match needs the byte count to agree exactly *and* the running
/// time to the second, so a re-encode is a different file here — which is the right
/// answer, because it is a different file.
enum FileFingerprint {
    static func of(sizeBytes: Int64?, durationMs: Int?) -> String? {
        // Both, or nothing: a library full of files whose duration couldn't be read would
        // otherwise fold together on size alone.
        guard let sizeBytes, sizeBytes > 0, let durationMs, durationMs > 0 else { return nil }
        return "\(sizeBytes)-\(durationMs / 1000)"
    }

    static func of(_ track: Track) -> String? {
        of(sizeBytes: track.sizeBytes, durationMs: track.durationMs)
    }
}
