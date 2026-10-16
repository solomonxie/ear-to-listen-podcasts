# 03 Providers and credentials (`Sources/Providers`, `Sources/Services`)

Summary: SigV4 (header and presigned), the Azure SAS and the GCS V4 signed URL are correct. The Azure Shared Key resource string is not: it signs the decoded path, so every blob operation on a name with a space or non-ASCII character returns 403. The never-overwrite-audio rule depends on a `try?` HEAD, so any HEAD failure counts as "key is free". S3 key paths lose empty segments. AWS buckets with dots in the name can't be added. Secrets stay in the keychain: none are in UserDefaults, logs or backups. **P0 0 · P1 5 · P2 2 · P3 16**

## P1

**1. Azure Shared Key signs the decoded blob path, so HEAD, PUT and DELETE fail with 403 for any blob name that has to be escaped.**
`Azure/SharedKey.swift:124`; affects `Azure/AzureBlobProvider.swift:107-124`, `:146-162`
- `canonicalizedResource` builds `"/\(account)\(url.path)"`. `URL.path` is percent-decoded. Azure's spec, and every official SDK (Go: `u.EscapedPath()`, with the comment "encoded exactly as it is in the URI"), signs the path as it was sent. The URL is built with `RFC3986.encodePath`, so `ep 1.mp3` goes out as `ep%201.mp3` but is signed as `ep 1.mp3`.
- Scenario: an Azure folder has `My Show 01.mp3`. The transcript sidecar `My Show 01.vtt` fails to write (`AuthenticationFailed`, HTTP 403). Delete-for-good fails. `metadata` fails, and `uploadEpisode`'s `try?` reads that failure as "free" (#2). Listing still works because container names never need escaping, and streaming works because the SAS correctly signs the raw name. So the bug appears only on writes, and the error looks like bad credentials.
- `AzureBlobTests` signs a container listing only, never a blob path that needs escaping.
- Fix: `"/\(account)" + (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path)`. Add a test that signs a PUT to `podcasts/ep 1.vtt`, checked against an SDK-computed value.

**2. `uploadEpisode` treats any `metadata` failure as "nothing there", so a failed HEAD lets it overwrite an existing episode.**
`Provider.swift:153-156`
- `if (try? await metadata(forFileID: key)) != nil { throw … }` gives the same answer for a 404, a 403, a timeout, a 5xx, an offline blip and a GCS token-exchange failure.
- Scenario: the listing the caller used to dodge taken names is stale, because the folder changed on another device. The HEAD for `ep-01.mp3` times out or gets a 503, and the PUT then succeeds and replaces the listener's audio. That breaks the one rule `CloudWrite` exists for, and the loss can't be undone.
- Fix: treat only an explicit not-found as free (S3 `HTTP 404`/`NoSuchKey`, Azure 404, GCS 404, local `fileNoSuchFile`) and rethrow everything else. Better, make the write itself conditional, which also removes the extra request per upload:
  - S3: `If-None-Match: *` (AWS supports it since 2024; check COS and OSS).
  - Azure: `If-None-Match: *`.
  - GCS: `ifGenerationMatch=0`.
  - Local: `.withoutOverwriting`.

**3. S3 key paths drop empty segments, so requests for keys with `//`, a leading `/` or a trailing `/` go to a different object.**
`S3/S3RestClient.swift:19`
- `key.split(separator: "/")` uses the default `omittingEmptySubsequences: true`, so `shows//ep.mp3` is requested as `shows/ep.mp3`. Azure and GCS use `RFC3986.encodePath`, which keeps empty segments.
- Scenario: a key written by a tool that joined `prefix/` + `/ep.mp3` is listed and synced, then returns 404 on play, HEAD and download. Deleting it for good sends `DELETE shows/ep.mp3`. If that key exists, a different episode is deleted. S3 also returns 204 for a missing key, so the call reports success either way.
- Fix: `RFC3986.encodePath(key)`. The canonical URI must then come from the same encoded string, not from `url.path`, because `URL.path` strips a trailing slash (see P3 "SigV4 re-derives the canonical URI and query").

**4. AWS region detection uses the virtual-hosted URL, so an AWS bucket with a dot in its name can't be added.**
`S3/S3Provider.swift:57`; called unconditionally for AWS at `Screens/Settings/AddCloudSourceView.swift:299-301`
- `https://my.podcasts.s3.amazonaws.com/` fails TLS against the `*.s3.amazonaws.com` certificate. `BucketEndpoint` handles exactly this case (`usesPathStyle`), but detection runs first, and `detectsRegion` means the form never asks for a region instead. The user sees "An SSL error has occurred" and has no workaround.
- Fix: use the path-style URL for detection when the bucket contains a dot: `https://s3.amazonaws.com/<bucket>`. A 301 or 403 from it still carries `x-amz-bucket-region`. Fall back to a region picker if detection fails.

**5. PLAUSIBLE: the GCS bucket name isn't escaped, and URL construction force-unwraps, so a malformed bucket name crashes on "Test connection".**
`GoogleCloud/GoogleCloudStorageProvider.swift:46`, `:99`, `:137`, `:165`, `:171`
- The path is `"/b/\(bucket)/o"` with the bucket as typed (trimmed only), passed to `URLComponents(string:)!`. A bucket containing a space, `%` or another character `URLComponents(string:)` rejects makes it return nil, and the `!` crashes. (Uncertain because iOS 17 relaxed `URL(string:)` parsing. Whether `URLComponents(string:)` also relaxed it wasn't verified.) `S3RestClient.swift:23`, `:26` and `S3Provider.swift:57` have the same force-unwrap pattern with the host.
- Fix: `RFC3986.encode(bucket)` in the path. Build URLs without `!` and throw a `badBucketName` error. Validate bucket names in `AddCloudSourceView` against each cloud's rules (`[a-z0-9.-_]`), which also catches `bucket/folder` and `s3://…` pasted into the bucket field.

## P2

**6. Azure listing creates a `DateFormatter` for every blob.**
`Azure/AzureBlobProvider.swift:248`; `Azure/SharedKey.swift:142-148`
- `parseRFC1123` creates and configures a new `DateFormatter` per call, and the list parser calls it once per `<Last-Modified>`, up to 5,000 times per page. `GoogleCloudStorageProvider.Timestamps` already avoids this for the same reason ("building one for each of a few thousand files is work for nothing").
- Scenario: syncing a 20k-blob container creates 20k formatters, which costs seconds of CPU on an older phone and runs every time the library refreshes.
- Fix: keep one formatter on the per-parse `Delegate`, as `S3ListParser` does.

**7. `GoogleAccessTokens` doesn't coalesce concurrent exchanges, although its doc comment says it does.**
`GoogleCloud/ServiceAccount.swift:143-156`
- The actor is re-entrant. While the first `token(for:)` waits on `exchange`, a second call finds no cache entry and starts its own exchange. Sync, playback (`streamURL` doesn't need a token, but `metadata`/`download` do) and backup starting together each sign a JWT (parsing the RSA key each time, see P3) and POST to the token endpoint.
- Fix: cache `Task<(token, expiresAt), Error>` per `clientEmail` and await the in-flight task. Remove it on failure.

## Improvements (P3)

- The default `download` maps every non-2xx to `missingFile`, "No file at …". Azure and GCS use it, so an expired SAS, a revoked key or a 403 reads as "missing". Throw a status-carrying error and keep `missingFile` for 404. `Provider.swift:125-131`
- `downloadBackup` swallows every error (`try? listFiles`, `try? download`). Offline, a 403 or a GCS token failure all read as "no backup yet", and `FirstRunRestore.swift:47` then skips the restore without telling anyone. Only an empty listing should mean "none". Rethrow the rest. `CloudBackup.swift:58-63`
- Listing parsers ignore `XMLParser.parse()`'s result and `<IsTruncated>`. A response that fails to parse partway through (for example a key with characters invalid in XML, since `encoding-type=url` isn't requested) returns a partial page with no token. The loop then ends and the sync receives a short listing. PLAUSIBLE: if COS or OSS answered `list-type=2` with V1 paging (`NextMarker`), the same thing would happen after 1,000 keys. Fix: throw on parse failure, and throw if `IsTruncated` is true with no token. `S3/S3RestClient.swift:156-161`, `:224`; `Azure/AzureBlobProvider.swift:206-211`, `:256`
- HEAD errors have no body, so `S3Error` reads "HTTP 403: (HTTP 403)". `AzureError` and `GoogleCloudError` have the same shape. Map 403 → "access denied (check the key's permissions)", 404 → "not found", and `RequestTimeTooSkewed`/`invalid_grant` → "check the device clock". `S3/S3RestClient.swift:63`, `:114-118`, `:137`
- Every stream URL expires after 3,600 s (S3, Azure SAS, GCS). A pause of more than an hour, or a long episode streamed without a finished cache, depends on the single `.failed` retry. Step 02 notes that only `.failed` is observed. All three schemes allow much longer expiry (S3 and GCS up to 7 days). Use something like 12 h, or the episode length plus a margin. `S3/SigV4.swift:131`, `Azure/SharedKey.swift:78`, `GoogleCloud/ServiceAccount.swift:208`
- Clock skew: the GCS JWT uses `iat = now`, so a device clock running a few minutes fast gets `invalid_grant`. SigV4 header auth fails beyond ±15 min. Backdate `iat` by 60 s, and show skew errors as a clock problem. `GoogleCloud/ServiceAccount.swift:169-170`
- A GCS token is never dropped on a 401, so a revoked or rotated key keeps failing until the cached expiry (up to an hour). Invalidate the cache entry and retry once on 401. `GoogleCloud/ServiceAccount.swift:152`, `GoogleCloudStorageProvider.swift:178-180`
- `GoogleServiceAccount.sign` parses the PEM and creates a `SecKey` on every call (each stream URL, each token). Parse it once in `init`, which also rejects a bad key at add time instead of at first use. `GoogleCloud/ServiceAccount.swift:38-39`
- An Azure account key that isn't valid base64 signs with `""`, and the service answers with a generic 403. Validate it in `AzureBlobProvider.init`. `Azure/SharedKey.swift:23`
- `EndpointSuffix` in the connection string is ignored and the host is hard-coded to `blob.core.windows.net`, so Azure China (`core.chinacloudapi.cn`) and Azure Government accounts can't connect. Store and use the suffix. `Azure/ConnectionString.swift:19-21`, `Azure/AzureBlobProvider.swift:27`
- SigV4 re-derives the canonical URI and query. `sign` signs `url.query` verbatim, which is canonical only because `S3RestClient.url` happens to build it that way. Both `sign` and `presignedURL` rebuild the canonical URI from the decoded `url.path` and encode it again. Take the canonical path and query from `URLComponents.percentEncodedPath` and `percentEncodedQuery`, or pass them in. `S3/SigV4.swift:98`, `:102`, `:149`
- No STS session token (`x-amz-security-token`), so temporary or role credentials can't be used. Only worth adding if someone asks for it. `S3/SigV4.swift:15-20`
- Security-scoped bookmarks:
  - `isStale` is never checked, so a stale bookmark isn't recreated and re-saved. It keeps resolving until the next move, then the source needs "remove and re-add".
  - `startAccessingSecurityScopedResource` is never balanced, and every `ProviderManager.invalidate` builds a new provider and opens another scope. That leaks the kernel resources Apple warns about.
  - Fix: refresh stale bookmarks into the keychain, and have the provider stop access in a holder's `deinit`.
  - `Local/LocalFilesProvider.swift:89-94`, `:58-64`
- Local folder listing:
  - One file whose `resourceValues` throws aborts the whole listing, because of the `try` inside the loop.
  - The enumerator has no `errorHandler`, so unreadable subtrees vanish silently.
  - Hidden files and iCloud `.icloud` placeholders aren't skipped.
  - The loop never checks `Task.isCancelled`.
  - `Local/LocalFilesProvider.swift:112-133`
- `CredentialStore.set` deletes the item and then adds it, so if `SecItemAdd` fails the old credential is already gone. Use `SecItemUpdate`, and add the item only when the update returns `errSecItemNotFound`. `CredentialStoreError` has no `LocalizedError`, so a locked keychain (for example a background launch before first unlock) shows "CredentialStoreError error 0". `Services/Credentials/CredentialStore.swift:4-6`, `:11-23`
- The keychain class is `kSecAttrAccessibleAfterFirstUnlock` (not `ThisDeviceOnly`). That's correct for background sync. Cloud keys and the GCS private key therefore migrate to a new phone through an encrypted backup. That's a reasonable trade-off because it restores connections, but write it down as a deliberate choice. `Services/Credentials/CredentialStore.swift:18`
- Verified, no issue:
  - SigV4 escapes space, unicode (UTF-8 bytes, uppercase hex), `+`, `=`, `~` (unreserved) and `/` (kept in the path) correctly.
  - The query is sorted by encoded name then value. The payload hash is the body's SHA-256 for PUT and `UNSIGNED-PAYLOAD` for presigned URLs.
  - The Azure Shared Key field order (12 fields, empty `Content-Length` for 0) and the 16-field SAS for `2021-08-06` are correct.
  - GCS `GOOG4-RSA-SHA256` is correct.
  - Paging is correct: S3 token, Azure empty `<NextMarker/>`, GCS `nextPageToken`.
  - URLSession's async APIs throw on cancellation, so the paging loops stop.
  - No secrets are in UserDefaults or logs, and none are in the backup archive.

## Test gaps

- Azure Shared Key over a blob path that needs escaping (`ep 1.vtt`, unicode) (#1).
- `uploadEpisode` when `metadata` throws something other than not-found: it must not write (#2).
- S3 URL and signature for keys with `//`, a leading `/` and unicode, checked against an AWS-computed signature (#3).
- `detectRegion` URL for a dotted bucket (#4).
- GCS and S3 URL construction with bad bucket names: they should throw, not crash (#5).
- `GoogleAccessTokens`: two concurrent `token` calls make one exchange (#7).
- List parsers: a truncated or malformed page throws instead of returning a partial page.
