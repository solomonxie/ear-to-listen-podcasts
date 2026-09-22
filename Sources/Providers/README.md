# Cloud Providers

`CloudProvider` protocol (list/metadata/stream/download/write/test-connection)
plus a `CloudProviderRegistry` that maps a provider type string to a factory, so
adding a backend means implementing the protocol and registering it in
`EarToListenApp.init()` — nothing else has to change.

`CloudSourceKind` is the list of clouds and the only place they differ in name:
the type string stored on a `ProviderRecord`, what each console calls the two
halves of a credential, whether a region is detected or picked, and the
`s3://`/`cos://`/`oss://`/`az://`/`gs://` shorthand a source row shows.

| Kind | Provider | Auth | Region |
|---|---|---|---|
| Amazon S3 (`s3`) | `S3Provider` | SigV4 key pair | detected from the bucket |
| Tencent COS (`cos`) | `S3Provider` | SigV4 (SecretId/SecretKey) | picked |
| Alibaba OSS (`oss`) | `S3Provider` | SigV4 (AccessKey pair) | picked |
| Azure Blob (`azure`) | `AzureBlobProvider` | Shared Key (account + key) | in the host |
| Google Cloud (`gcs`) | `GoogleCloudStorageProvider` | service account JSON | none |

COS and OSS are not separate implementations: they answer the same requests with
the same signature on their own hostnames, so only `BucketEndpoint` knows the
difference. Azure and Google each need their own provider — a different
signature and a different wire format — but both file objects by flat key with
`/` as the only hierarchy, so everything above this folder treats all five the
same. iCloud/Drive/Dropbox/OneDrive are backlogged behind the same protocol.

Signing is hand-written on purpose (`S3/SigV4.swift`, `Azure/SharedKey.swift`,
`GoogleCloud/ServiceAccount.swift`): published algorithms over plain
`URLSession`, against three SDKs that would each cost more than the whole app.

Writes go through one of two gates in the protocol extension, never `write`
directly: `upload` for what the app makes itself (a transcript sidecar, a
library archive), which refuses a playable extension, and `uploadEpisode` for a
file the listener picked, which requires one and refuses a key that already
exists. `CloudWrite` holds both rules, so a new backend implements one raw
`write` and inherits the never-overwrite-audio promise.

`ProviderManager` resolves a `ProviderRecord` (from `Sources/DB`) into a live
provider instance and owns its settings/credentials lifecycle. `CloudBackup`
adds the library archive's folder to every provider at once — it's written
through `upload`/`listFiles`/`download` alone, so a new backend gets backup and
restore for free.

## Resolution Workflow

```
EarToListenApp.swift:init()
  registers a factory per CloudSourceKind, plus "local"
        │
        ▼ (later, on sync or playback)
Sources/DB/ProviderStore.swift:active() → [ProviderRecord]
        │ for each record
        ▼
ProviderManager.swift:provider(for: record)
        ├─ cache hit ──► return cached CloudProvider
        └─ cache miss
              │ CredentialStore reads this record's settings from Keychain
              ▼
        Provider.swift:CloudProviderRegistry.makeProvider(for: config)
              │ dispatches on config.type
              ├─ "s3"/"cos"/"oss" ──► S3/S3Provider.swift:init(config:)
              │                         one client, three hostnames
              │                         (S3/BucketEndpoint.swift)
              ├─ "azure" ──────────► Azure/AzureBlobProvider.swift:init(config:)
              ├─ "gcs" ────────────► GoogleCloud/GoogleCloudStorageProvider.swift
              │                         service account → OAuth token, cached
              └─ "local" ──────────► Local/LocalFilesProvider.swift:init(config:)
                               resolves security-scoped bookmarks: one folder,
                               or the individual episodes picked from Files
                               (`LocalFileEntry`, keyed by the path each is
                               filed under — read-only, no folder for sidecars).
                               No longer creatable: episodes go into a bucket
                               now ("Upload from Files"), so this only reads
                               sources added before that.
              │ caches the instance
              ▼
caller: .listFiles(inFolder:) / .streamURL(forFileID:) / .testConnection()
```
