import Foundation

/// Which cloud a remote source lives in, and what that cloud calls the things it needs.
///
/// One list, because three separate parts of the app were each asking "is this record a
/// bucket?" by spelling out `== "s3"`: the Remote section, the backup destination, and
/// the add-a-source screen. A backend nobody could see or back up to isn't added, so the
/// answer belongs in one place — the raw value *is* the stored `ProviderRecord.type`, so
/// `"s3"` keeps meaning what it meant before any of the others existed.
///
/// Tencent COS and Alibaba OSS aren't separate implementations: they answer the same
/// S3 requests with the same SigV4 signature on their own hostnames, so they share
/// `S3Provider` and differ only in `BucketEndpoint`. Azure and Google Cloud each need
/// their own provider — a different signature and a different wire format.
enum CloudSourceKind: String, CaseIterable, Identifiable, Sendable {
    case amazonS3 = "s3"
    case tencentCos = "cos"
    case aliyunOss = "oss"
    case azureBlob = "azure"
    case googleCloudStorage = "gcs"

    init?(providerType: String) { self.init(rawValue: providerType) }

    var id: String { rawValue }
    var providerType: String { rawValue }

    /// Whether this is one of the clouds `S3Provider` can talk to.
    var speaksS3: Bool {
        switch self {
        case .amazonS3, .tencentCos, .aliyunOss: true
        case .azureBlob, .googleCloudStorage: false
        }
    }

    var name: String {
        switch self {
        case .amazonS3: "Amazon S3"
        case .tencentCos: "Tencent Cloud COS"
        case .aliyunOss: "Alibaba Cloud OSS"
        case .azureBlob: "Azure Blob Storage"
        case .googleCloudStorage: "Google Cloud Storage"
        }
    }

    /// What fits on a source row next to the folder path.
    var shortName: String {
        switch self {
        case .amazonS3: "S3"
        case .tencentCos: "COS"
        case .aliyunOss: "OSS"
        case .azureBlob: "Azure"
        case .googleCloudStorage: "GCS"
        }
    }

    /// The `scheme://bucket/folder/` shorthand each cloud's own tooling uses — what a
    /// source row shows, so two connections into the same folder name are still told apart.
    var uriScheme: String {
        switch self {
        case .amazonS3: "s3"
        case .tencentCos: "cos"
        case .aliyunOss: "oss"
        case .azureBlob: "az"
        case .googleCloudStorage: "gs"
        }
    }

    /// Azure files blobs in containers; everyone else calls it a bucket.
    var containerLabel: String { self == .azureBlob ? "Container" : "Bucket" }

    enum Credential: Sendable {
        case keyPair(idLabel: String, secretLabel: String)
        case serviceAccountJSON
    }

    /// Named as the cloud's own console names them — a Tencent user is looking for
    /// "SecretId", not "Access Key ID", and typing the wrong half is the whole failure.
    var credential: Credential {
        switch self {
        case .amazonS3: .keyPair(idLabel: "Access Key ID", secretLabel: "Secret Access Key")
        case .tencentCos: .keyPair(idLabel: "SecretId", secretLabel: "SecretKey")
        case .aliyunOss: .keyPair(idLabel: "AccessKey ID", secretLabel: "AccessKey Secret")
        case .azureBlob: .keyPair(idLabel: "Storage account name", secretLabel: "Account key")
        case .googleCloudStorage: .serviceAccountJSON
        }
    }

    /// Only AWS tells us the region itself (`x-amz-bucket-region`, no credentials needed),
    /// so it's the only one that never asks.
    var detectsRegion: Bool { self == .amazonS3 }

    /// The regions to pick from. Empty means the region is either detected or not part of
    /// addressing this cloud at all — Azure derives its host from the account name, and
    /// Google's JSON API has one global host.
    var regions: [String] {
        switch self {
        case .tencentCos: Self.tencentCosRegions
        case .aliyunOss: Self.aliyunOssRegions
        case .amazonS3, .azureBlob, .googleCloudStorage: []
        }
    }

    /// COS's public regions, as its console spells them. Financial-cloud and
    /// dedicated-zone regions are left out — those need a different endpoint domain
    /// altogether, not just another id here.
    private static let tencentCosRegions = [
        "ap-beijing", "ap-nanjing", "ap-shanghai", "ap-guangzhou", "ap-chengdu",
        "ap-chongqing", "ap-hongkong", "ap-singapore", "ap-jakarta", "ap-seoul",
        "ap-tokyo", "ap-bangkok", "ap-mumbai", "na-siliconvalley", "na-ashburn",
        "na-toronto", "sa-saopaulo", "eu-frankfurt",
    ]

    /// OSS regions without the `oss-` prefix the endpoint adds back — the id Alibaba's
    /// console shows for a bucket is `cn-hangzhou`, not `oss-cn-hangzhou`.
    private static let aliyunOssRegions = [
        "cn-hangzhou", "cn-shanghai", "cn-nanjing", "cn-fuzhou", "cn-qingdao",
        "cn-beijing", "cn-zhangjiakou", "cn-huhehaote", "cn-wulanchabu", "cn-shenzhen",
        "cn-heyuan", "cn-guangzhou", "cn-chengdu", "cn-hongkong", "us-west-1",
        "us-east-1", "ap-northeast-1", "ap-northeast-2", "ap-southeast-1",
        "ap-southeast-2", "ap-southeast-3", "ap-southeast-5", "ap-southeast-6",
        "ap-southeast-7", "ap-south-1", "eu-central-1", "eu-west-1", "me-east-1",
    ]
}

extension ProviderRecord {
    /// `nil` for a source that isn't a bucket — local files, the demo content.
    var cloudKind: CloudSourceKind? { CloudSourceKind(providerType: type) }
}
