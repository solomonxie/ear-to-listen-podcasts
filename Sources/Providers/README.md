# Cloud Providers

`CloudProvider` protocol (list/metadata/stream/test-connection) plus a
`CloudProviderRegistry` that maps a provider type string to a factory, so
adding a backend means implementing the protocol and registering it in
`BringYourOwnPodcastsApp.init()` — nothing else has to change. S3 and local
files are implemented; iCloud/Drive/Dropbox/OneDrive/Aliyun OSS/Tencent COS
are backlogged behind the same protocol.

`ProviderManager` resolves a `ProviderRecord` (from `Sources/DB`) into a live
provider instance and owns its settings/credentials lifecycle.

## Structure

```
Sources/Providers/
├── Provider.swift            CloudProvider protocol + CloudFile, CloudProviderRegistry
├── ProviderManager.swift     ProviderRecord → live CloudProvider (Keychain-backed, cached)
├── S3/
│   └── S3Provider.swift        AWS S3-backed CloudProvider
└── Local/
    └── LocalFilesProvider.swift  on-device Documents folder as a CloudProvider
```
