# Bring-Your-Own-Podcasts Player — Implementation Plan

See [design doc](./byo-podcast-player.md) for reasoning behind these choices.

## Phase 1: Foundations
Scaffold, local DB, secure credential storage, and the two source protocols
(storage, playlist import) — everything else (adapters, playback, UI) is
built against these. All six tasks touch disjoint files and can run fully
in parallel.

- [x] T1.1 XcodeGen `project.yml` + app entry point (SwiftUI `App`, empty root view), iOS bundle id, background-audio capability — see `project.yml`, `Sources/App` — depends: none
- [x] T1.2 GRDB schema + migrations: tracks, albums, artists, playlists, playlist_tracks, providers, import_sources; FTS5 for search — see `Sources/DB` — depends: none
- [x] T1.3 Keychain credential service: generic get/set/delete secret by key, used by all provider and import-source adapters — see `Sources/Services/Credentials` — depends: none
- [x] T1.4 `CloudProvider` protocol (listFiles, getMetadata, getStreamURL, testConnection) + provider registry — see `Sources/Providers/Provider.swift` — depends: none
- [x] T1.5 `PlaylistImportSource` protocol (authenticate, listPlaylists, getPlaylistTracks) + registry — see `Sources/Importers/ImportSource.swift` — depends: none
- [x] T1.6 Add SPM dependencies to `project.yml` (GRDB.swift, aws-sdk-swift/AWSS3, GoogleSignIn-iOS) — see `project.yml` — depends: none
- [x] T1.7 String Catalog foundation: `Resources/Localizable.xcstrings` (English source + Mandarin/zh-Hans), wire existing scaffold text through it — see `Resources/Localizable.xcstrings` — depends: none

## Phase 2: S3 provider & playback engine
Adapters implement the Phase 1 protocols against real backends; the playback
engine only needs the app scaffold. Both can proceed in parallel once
Phase 1 lands. S3 is the only storage provider being built now — Google
Drive/Dropbox/OneDrive, WebDAV, and Apple Music import are all backlogged
(see bottom of this file); Spotify import ships alongside S3.

- [x] T2.1 S3Provider adapter: access key/secret auth, list objects, presigned URL generation via `AWSS3` — see `Sources/Providers/S3` — depends: T1.4, T1.6
- [x] T2.2 Playback engine: `AVQueuePlayer` setup, queue, background audio session, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` for lock-screen/Control Center — see `Sources/Playback` — depends: T1.1
- [x] T2.3 SpotifyImportSource adapter: OAuth (Authorization Code + PKCE via `ASWebAuthenticationSession`), list playlists, fetch tracks via Spotify Web API — see `Sources/Importers/Spotify` — depends: T1.5
- [x] T2.4 Fuzzy track matcher: normalize + compare imported track metadata against local library, confidence score, unmatched list — see `Sources/Importers/Matcher.swift` — depends: T1.2

## Phase 3: Settings UI & library sync
Settings needs working adapters + Keychain to configure and test real
credentials; the sync engine needs the DB + adapters to populate the library.
Independent view/files, can run in parallel.

- [x] T3.1 Settings screen: add/edit/remove provider credentials, test-connection action, active-source multi-select — see `Sources/Screens/Settings` — depends: T1.3, T2.1
- [x] T3.2 Library sync engine: list files from active providers, extract tag metadata (AVAsset/ID3), upsert into GRDB — see `Sources/Library/Sync.swift` — depends: T1.2, T2.1

## Phase 4: Core screens
The Spotify/YouTube-Music-style UI, built once there's a populated library
and a working player to drive it. Each screen is its own SwiftUI view tree,
safe to parallelize.

- [x] T4.1 Library browse (Artists/Albums/Tracks tabs, pull-to-refresh triggers sync) — see `Sources/Screens/Library` — depends: T3.2
- [x] T4.2 Search screen (GRDB FTS5 query over local index) — see `Sources/Screens/Search` — depends: T3.2
- [x] T4.3 Now Playing screen (art, progress, transport controls) — see `Sources/Screens/NowPlaying` — depends: T2.2
- [x] T4.4 Queue screen (up-next list, reorder) — see `Sources/Screens/Queue` — depends: T2.2
- [x] T4.5 Playlists (create/edit, add/remove tracks) — see `Sources/Screens/Playlists` — depends: T1.2, T4.1
- [x] T4.6 Playlist import screen: connect Spotify, pick playlists to import, review/confirm fuzzy-matched + unmatched tracks — see `Sources/Screens/ImportPlaylists` — depends: T2.3, T2.4, T4.5

## Phase 5: Offline cache & release polish
Hardening once the core app works end-to-end: reduces re-fetching, handles
real-world failures, and gets the build ready to ship.

- [x] T5.1 LRU disk cache for streamed audio, backed by provider stream URLs — see `Sources/Playback/Cache.swift` — depends: T2.2
- [x] T5.2 Error/retry handling: expired presigned URLs, offline state — see `Sources/Providers` — depends: T2.1
- [x] T5.3 App icon, launch screen, TestFlight build config (signing, Xcode Cloud or manual `xcodebuild archive` — no EAS/Expo build service) — see `project.yml` — depends: T1.1
- [x] T5.4 QA pass: unit tests for provider/importer adapters + sync engine + matcher, manual playback test on device — see `Tests` — depends: T4.1, T4.2, T4.3, T4.4, T4.5, T4.6, T5.1, T5.2

## Phase 6: Sync & Backup
Fills in the four "coming soon" rows under Settings ▸ Sync & Backup. Backs up
app metadata only (playlists, provider/import-source list) — not audio files
(already on the provider) or credentials (Keychain-only, re-enter after a
restore). Note: the real `Playlists` table this reads/writes is not yet wired
to the Playlists screen (`Sources/Screens/Playlists` still runs on
`MockLibraryStore`), so playlist backup/restore is correct but inert — always
empty — until that screen is wired to `Sources/DB`; that wiring is its own,
separate task, not scheduled here.

- [x] T6.1 `LibrarySnapshot` Codable model + `BackupService` (build from DB, encode/decode, apply-with-matching by providerID+filePath) — see `Sources/Backup` — depends: T1.2
- [x] T6.2 `S3Provider.uploadBackup`/`downloadBackup`: fixed-key JSON object in the bucket — see `Sources/Providers/S3` — depends: T2.1, T6.1
- [x] T6.3 Wire Settings ▸ Sync & Backup: Export/Import via `.fileExporter`/`.fileImporter`, Backup/Restore via the active S3 provider — see `Sources/Screens/Settings` — depends: T6.1, T6.2
- [x] T6.4 Unit tests: snapshot round-trip, restore matching (hit/miss by providerID+filePath), idempotent re-apply — see `Tests` — depends: T6.1

## Dropped (not backlogged)
- Expo / Expo Go and the `expo` Claude Code plugin: an Expo-account login,
  a second runtime that can't run the native pieces this app is made of,
  and enough flakiness to muddle "my bug" with "Expo's bug". The dev loop is
  `xcodegen generate` + Xcode/Simulator, and the ship path is `xcodebuild
  archive` or Xcode Cloud. Nothing in the repo references Expo; don't
  reintroduce it.

## Backlog (not scheduled)
- GoogleDriveProvider adapter: OAuth via `GoogleSignIn-iOS`, Drive REST v3
  list files/download URL — same `CloudProvider` protocol from T1.4 already
  accommodates it.
- DropboxProvider adapter: OAuth + REST via `SwiftyDropbox`.
- OneDriveProvider adapter: OAuth via `MSAL`, Microsoft Graph REST.
- Apple Music playlist import (`MusicKit` adapter + wiring into T4.6) —
  deferred behind Spotify; same `PlaylistImportSource` protocol from T1.5
  already accommodates it whenever it's picked up.
