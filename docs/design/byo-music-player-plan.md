# Bring-Your-Own-Music Player — Implementation Plan

See [design doc](./byo-music-player.md) for reasoning behind these choices.

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

## Phase 2: Provider adapters & playback engine
Adapters implement the Phase 1 protocols against real backends; the playback
engine only needs the app scaffold. Both can proceed in parallel once
Phase 1 lands.

- [ ] T2.1 S3Provider adapter: access key/secret auth, list objects, presigned URL generation via `AWSS3` — see `Sources/Providers/S3` — depends: T1.4, T1.6
- [ ] T2.2 GoogleDriveProvider adapter: OAuth via `GoogleSignIn-iOS`, Drive REST v3 list files, download URL — see `Sources/Providers/GoogleDrive` — depends: T1.4, T1.6
- [ ] T2.3 WebDAV/"other" provider adapter, proving the protocol extends beyond S3/Drive — see `Sources/Providers/WebDAV` — depends: T1.4
- [ ] T2.4 Playback engine: `AVQueuePlayer` setup, queue, background audio session, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` for lock-screen/Control Center — see `Sources/Playback` — depends: T1.1
- [ ] T2.5 SpotifyImportSource adapter: OAuth (Authorization Code + PKCE via `ASWebAuthenticationSession`), list playlists, fetch tracks via Spotify Web API — see `Sources/Importers/Spotify` — depends: T1.5
- [ ] T2.6 AppleMusicImportSource adapter: `MusicKit` authorization, list playlists, fetch tracks — see `Sources/Importers/AppleMusic` — depends: T1.5
- [ ] T2.7 Fuzzy track matcher: normalize + compare imported track metadata against local library, confidence score, unmatched list — see `Sources/Importers/Matcher.swift` — depends: T1.2

## Phase 3: Settings UI & library sync
Settings needs working adapters + Keychain to configure and test real
credentials; the sync engine needs the DB + adapters to populate the library.
Independent view/files, can run in parallel.

- [ ] T3.1 Settings screen: add/edit/remove provider credentials, test-connection action, active-source multi-select — see `Sources/Screens/Settings` — depends: T1.3, T2.1, T2.2, T2.3
- [ ] T3.2 Library sync engine: list files from active providers, extract tag metadata (AVAsset/ID3), upsert into GRDB — see `Sources/Library/Sync.swift` — depends: T1.2, T2.1, T2.2, T2.3

## Phase 4: Core screens
The Spotify/YouTube-Music-style UI, built once there's a populated library
and a working player to drive it. Each screen is its own SwiftUI view tree,
safe to parallelize.

- [ ] T4.1 Library browse (Artists/Albums/Tracks tabs, pull-to-refresh triggers sync) — see `Sources/Screens/Library` — depends: T3.2
- [ ] T4.2 Search screen (GRDB FTS5 query over local index) — see `Sources/Screens/Search` — depends: T3.2
- [ ] T4.3 Now Playing screen (art, progress, transport controls) — see `Sources/Screens/NowPlaying` — depends: T2.4
- [ ] T4.4 Queue screen (up-next list, reorder) — see `Sources/Screens/Queue` — depends: T2.4
- [ ] T4.5 Playlists (create/edit, add/remove tracks) — see `Sources/Screens/Playlists` — depends: T1.2, T4.1
- [ ] T4.6 Playlist import screen: connect Spotify/Apple Music, pick playlists to import, review/confirm fuzzy-matched + unmatched tracks — see `Sources/Screens/ImportPlaylists` — depends: T2.5, T2.6, T2.7, T4.5

## Phase 5: Offline cache & release polish
Hardening once the core app works end-to-end: reduces re-fetching, handles
real-world failures, and gets the build ready to ship.

- [ ] T5.1 LRU disk cache for streamed audio, backed by provider stream URLs — see `Sources/Playback/Cache.swift` — depends: T2.4
- [ ] T5.2 Error/retry handling: expired presigned URLs, Google token refresh, offline state — see `Sources/Providers` — depends: T2.1, T2.2
- [ ] T5.3 App icon, launch screen, TestFlight build config (signing, `eas`-equivalent: Xcode Cloud or manual archive) — see `project.yml` — depends: T1.1
- [ ] T5.4 QA pass: unit tests for provider/importer adapters + sync engine + matcher, manual playback test on device — see `Tests` — depends: T4.1, T4.2, T4.3, T4.4, T4.5, T4.6, T5.1, T5.2
