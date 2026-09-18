# Cloud Providers

`CloudProvider` protocol (list/metadata/stream/test-connection) plus a
`CloudProviderRegistry` that maps a provider type string to a factory, so
adding a backend means implementing the protocol and registering it in
`EarToListenApp.init()` — nothing else has to change. S3 and local
files are implemented; iCloud/Drive/Dropbox/OneDrive/Aliyun OSS/Tencent COS
are backlogged behind the same protocol.

`ProviderManager` resolves a `ProviderRecord` (from `Sources/DB`) into a live
provider instance and owns its settings/credentials lifecycle.

## Resolution Workflow

```
EarToListenApp.swift:init()
  registers factories: "s3" → S3Provider.init, "local" → LocalFilesProvider.init
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
              ├─ "s3"    ──► S3/S3Provider.swift:init(config:)
              └─ "local" ──► Local/LocalFilesProvider.swift:init(config:)
                               resolves security-scoped bookmarks: one folder,
                               or the individual episodes picked from Files
                               (`LocalFileEntry`, keyed by the path each is
                               filed under — read-only, no folder for sidecars)
              │ caches the instance
              ▼
caller: .listFiles(inFolder:) / .streamURL(forFileID:) / .testConnection()
```
