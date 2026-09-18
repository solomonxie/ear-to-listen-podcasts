# Bring-Your-Own-Podcasts Player

## Problem
Spotify/YouTube Music have great streaming UX but only play licensed catalog
content. User owns music files sitting in their own cloud storage (S3 today,
maybe Drive/others later) and wants that same streaming-app experience on
iPhone, without hardcoding one storage backend.

## Goals
- Spotify/YouTube-Music-like iPhone app: browse, search, now-playing, queue,
  playlists, background audio, lock-screen/control-center controls.
- Storage backend is user-configured in Settings, not hardcoded: S3 ships
  first, `CloudProvider` protocol built so Google Drive/Dropbox/OneDrive
  slot in later without touching the rest of the app.
- Add/edit/remove/test credentials per provider; pick which sources feed the
  library. Credentials encrypted on-device (Keychain), never leave the device.
- Local library index (artist/album/track) built from provider file listings
  + tag metadata, so browse/search work without a backend server.
- Import playlists (track lists, not audio) from existing streaming apps and
  match each track against the local library by metadata, so a user's
  existing playlists carry over — limited to services with an official API.
- UI is localizable from the start: English and Mandarin (Simplified) at
  launch, more languages addable without touching view code.

## Non-goals
- No backend server, no multi-device account sync (v1) — device-local index.
- No social features (sharing, following, public playlists).
- No transcoding pipeline — plays whatever format AVPlayer supports natively.
- No cross-platform code — iOS only, native Swift; no Android version.
- No Expo / Expo Go anywhere — not as a preview client, not as build
  service, not as editor tooling. Removed outright, not backlogged; see
  "Options considered" for why.
- No DRM/licensing — user's own files only. Playlist import brings in track
  metadata (title/artist/album/duration) only, never audio — matched tracks
  must already exist in the user's own storage to be playable.
- No playlist import from services without an official API (e.g. YouTube
  Music) — scraping or unofficial APIs are out of scope regardless of demand.
- No WebDAV provider — dropped from scope entirely, not backlogged.
- No Google Drive, Dropbox, or OneDrive adapter in this pass — backlogged;
  S3 ships alone first, the others come later behind the same
  `CloudProvider` protocol.
- No Apple Music import in this pass — backlogged; Spotify import ships
  first, Apple Music (`MusicKit`) adapter revisited later.

## Options considered
- **Language/framework**: React Native/Expo (cross-platform, but every core
  feature here — background audio with rich metadata, Keychain, SQLite,
  MusicKit — needed a native module or bridge anyway) vs native Swift +
  SwiftUI, iOS-only (no bridge overhead, first-class access to AVFoundation/
  MediaPlayer/MusicKit/Security frameworks, smaller dependency surface) —
  chosen native Swift since the app is iPhone-only by requirement and every
  RN dependency it needed was a thin wrapper around one of these frameworks
  anyway.
- **Dev loop / preview client**: Expo Go (scan a QR, live-reload on device —
  but it needs an Expo account login, only runs what its prebuilt client
  already links so anything native means leaving it anyway, and was flaky
  enough in practice to cost more debugging time than it saved) vs plain
  Xcode + Simulator/device builds from the XcodeGen project (no account, no
  second runtime, the same binary that ships to TestFlight) — chosen the
  Xcode loop. On a one-person project the account, the extra client and the
  "is this Expo or my code?" ambiguity were pure overhead, so Expo Go and
  its tooling (down to the `expo` Claude Code plugin this repo used to
  enable) are removed rather than left as an optional path.
- **Project/build system**: hand-maintained `.xcodeproj` (fragile merge
  conflicts, opaque diffs) vs generated via **XcodeGen** from a checked-in
  `project.yml` (text, diffable, regenerate with one command) — chosen
  XcodeGen; the `.xcodeproj` itself is gitignored and regenerated.
- **Storage abstraction**: direct per-provider calls in views (simplest,
  couples UI to provider) vs a common `CloudProvider` protocol with adapter
  types (decoupled, easy to add providers) vs a backend proxy aggregating
  providers (most secure, but requires hosting infra — violates no-server
  goal) — chosen the protocol + adapters.
- **Credential storage**: UserDefaults plaintext (insecure) vs Keychain
  Services directly via the `Security` framework (OS-encrypted, no extra
  dependency, small enough to wrap in-house) vs a third-party wrapper library
  (unnecessary once there's no RN bridge to abstract) — chosen a thin
  first-party Keychain wrapper.
- **S3 access**: long-lived IAM access key/secret on-device via `aws-sdk-swift`
  (`AWSS3` product only — matches user's ask, no server needed, correct
  SigV4/presigning without hand-rolling it) vs STS temp credentials via a
  token-broker server (more secure, needs backend — violates no-server goal)
  vs hand-written SigV4 signing over `URLSession` (avoids the dependency, but
  presigning/canonical-request edge cases are easy to get subtly wrong) —
  chosen the official SDK for correctness.
- **Google Drive auth**: `GoogleSignIn-iOS` (official SDK, OAuth2+PKCE,
  refresh token handling built in) + Drive REST v3 over `URLSession` vs
  hand-rolled OAuth via `ASWebAuthenticationSession` (no dependency, but
  reimplements what the official SDK already does) — chosen the official SDK.
- **Dropbox auth**: `SwiftyDropbox` (Dropbox's official SDK, OAuth2 + REST
  client built in) vs hand-rolled OAuth (reimplements the official SDK) —
  chosen SwiftyDropbox.
- **OneDrive auth**: `MSAL` (Microsoft's official iOS auth library) +
  Microsoft Graph REST API over `URLSession` vs generic OAuth via
  `ASWebAuthenticationSession` (Microsoft's own docs steer integrators
  toward MSAL for Graph) — chosen MSAL.
- **Playback engine**: `AVFoundation` (`AVQueuePlayer`) + `MediaPlayer`
  framework (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`) — no
  dependency, exactly what Apple Music/Spotify build on — vs any third-party
  wrapper (adds nothing native Swift doesn't already expose directly).
- **Local index/DB**: `GRDB.swift` (mature SQLite wrapper, real SQL,
  migrations, FTS5 support) vs raw `sqlite3` C API (zero dependency, much
  more boilerplate) vs Core Data (heavier, weaker full-text search story) —
  chosen GRDB for the productivity win, single well-maintained dependency.
- **Streaming model**: stream directly from a signed URL via HTTP range
  requests (default, no full download) with an LRU disk cache layered on top
  for offline replay, vs download-first-then-play (unnecessary storage use
  for casual listening) — chosen streaming + cache.
- **Playlist import scope**: any service reachable via scraping/unofficial
  APIs (broad coverage, fragile, ToS risk) vs official-API services only
  (Spotify Web API, Apple MusicKit) — chosen official-API-only per explicit
  requirement; YouTube Music has no official playlist API and is out of
  scope, not deferred. Of the official-API services, Spotify ships first;
  Apple Music (`MusicKit`) is backlogged, not dropped — same rationale
  applies to it whenever it's picked back up.
- **Track matching**: exact string match only (simple, misses most real
  variants — remaster tags, "feat." ordering) vs normalized fuzzy match
  (strip punctuation/case, compare artist+title+duration tolerance) with a
  manual-confirm step for low-confidence/unmatched tracks — chosen fuzzy +
  confirm, since silent wrong matches are worse than asking the user once.
- **Localization**: Xcode **String Catalogs** (`.xcstrings`) — native,
  Xcode 15+, first-class SwiftUI integration (`Text("key")` resolves
  automatically), pluralization support, no dependency — vs legacy
  `Localizable.strings` per language (more files, more manual bookkeeping)
  vs a third-party i18n library (nothing native Swift doesn't already do) —
  chosen String Catalogs, one file (`Resources/Localizable.xcstrings`)
  holding every language.

## Decision
Native Swift + SwiftUI, iOS-only, project generated by XcodeGen from
`project.yml`. `CloudProvider` protocol with an S3 adapter
(`aws-sdk-swift`/`AWSS3`) shipping first — Google Drive (`GoogleSignIn-iOS`),
Dropbox (`SwiftyDropbox`), and OneDrive (`MSAL` + Graph API) adapters
backlogged behind it, same protocol. First-party Keychain wrapper over
`Security` for credentials. `GRDB.swift` local index
for library/search/playlists. `AVQueuePlayer` + `MediaPlayer` framework for
playback with full lock-screen/Control Center metadata. Stream via
presigned/direct URLs with an LRU disk cache for recently played tracks.
`PlaylistImportSource` protocol with a Spotify (Web API + OAuth) adapter now
— Apple Music (`MusicKit`) backlogged — feeding a fuzzy metadata matcher
that resolves imported tracks against the local library and surfaces
unmatched ones for manual fix. All user-facing strings go through a single
`Resources/Localizable.xcstrings` String Catalog, English + Mandarin
(Simplified) from the first screen onward.

## Risks / open questions
- Long-lived S3 keys on-device are exposed if the phone is compromised —
  mitigate by documenting a read-only, single-bucket IAM policy in the
  Settings help text; accepted risk for v1, not solved in-app.
- Lossless (FLAC) playback support via AVPlayer on iOS is inconsistent —
  verify against the user's actual file formats; no transcoding fallback
  planned for v1.
- Google Drive API pagination/rate limits for large libraries (1000s of
  files) — needs paged listing + background sync; revisit when Drive comes
  off the backlog.
- iOS background execution limits may throttle large background cache
  downloads — only address via `BackgroundTasks` framework if it becomes a
  real problem.
- No multi-device sync of playlists/playback position in v1 — open question
  whether iCloud key-value storage is worth adding later.
- Fuzzy track matching will misfire on live versions, remixes, and
  multi-disc albums — manual-confirm step is required, not optional.
- Apple MusicKit playlist/library read APIs require the user to have an
  active Apple Music subscription for some endpoints — revisit when Apple
  Music import comes off the backlog.
- Dropbox's SwiftyDropbox and Microsoft's MSAL both expect a registered
  app (App Key/Secret, or Azure AD app registration) plus a custom URL
  scheme for the OAuth redirect — revisit when those adapters come off the
  backlog.
- No CI/simulator automation set up yet — builds/tests run locally via
  `xcodebuild`; revisit if this becomes a bottleneck.
- `aws-sdk-swift`'s `smithy-swift` dependency ships a build-tool plugin that
  Xcode must trust before it can run; opening the project in Xcode.app shows
  a one-time "Trust & Enable" prompt, CLI builds need
  `-skipPackagePluginValidation` until that trust is recorded.
