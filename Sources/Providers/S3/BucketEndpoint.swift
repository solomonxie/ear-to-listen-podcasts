import Foundation

/// Where a bucket's S3 API answers. One host per cloud is the whole difference between
/// them: COS and OSS implement the same requests, the same SigV4 signing (service `s3`)
/// and the same XML, so every signed call routes through here instead of hard-coding
/// AWS's hostname.
///
/// Both non-AWS hosts are the vendors' own documented S3-compatible endpoints,
/// virtual-hosted style (bucket in the hostname), which is what they tell AWS SDK users
/// to configure. For COS the bucket name is the one with the APPID suffix —
/// `my-podcasts-1250000000` — exactly as its console shows it.
struct BucketEndpoint: Sendable {
    let kind: CloudSourceKind
    let bucket: String
    /// What the SigV4 credential scope names, too. COS verifies against it; OSS ignores it
    /// entirely, so the bucket's own region is both correct and the one worth showing.
    let region: String
    let host: String
    /// Virtual-hosted style everywhere, except an AWS bucket whose name contains a dot:
    /// those break TLS certificate matching on `*.s3.region.amazonaws.com`.
    let usesPathStyle: Bool

    /// `nil` for a cloud that doesn't speak S3 — Azure and Google have providers of their own.
    init?(kind: CloudSourceKind, bucket: String, region: String) {
        switch kind {
        case .amazonS3:
            usesPathStyle = bucket.contains(".")
            host = usesPathStyle ? "s3.\(region).amazonaws.com" : "\(bucket).s3.\(region).amazonaws.com"
        case .tencentCos:
            usesPathStyle = false
            host = "\(bucket).cos.\(region).myqcloud.com"
        // OSS answers the S3 API on a separate `s3.`-prefixed host; plain
        // `oss-<region>.aliyuncs.com` is its own native protocol, which shares the verbs
        // but not the signature.
        case .aliyunOss:
            usesPathStyle = false
            host = "\(bucket).s3.oss-\(region).aliyuncs.com"
        case .azureBlob, .googleCloudStorage:
            return nil
        }
        self.kind = kind
        self.bucket = bucket
        self.region = region
    }
}
