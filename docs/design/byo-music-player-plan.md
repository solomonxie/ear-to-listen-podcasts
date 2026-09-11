# Bring-Your-Own-Music Player — Implementation Plan

See [design doc](./byo-music-player.md) for reasoning behind these choices.

## Phase 1: Foundations
Scaffold, local DB, secure credential storage, and the two source interfaces
(storage, playlist import) — everything else (adapters, playback, UI) is
built against these. All five tasks touch disjoint files and can run fully
in parallel.

- [ ] T1.1 Scaffold Expo (TypeScript) app, iOS bundle id, EAS dev client build config — see `app/` — depends: none
- [ ] T1.2 SQLite schema + data access layer: tracks, albums, artists, playlists, playlist_tracks, providers, import_sources — see `src/db` — depends: none
- [ ] T1.3 Keychain credential service: generic get/set/delete secret by key, used by all provider and import-source adapters — see `src/services/credentials` — depends: none
- [ ] T1.4 `CloudProvider` TypeScript interface (listFiles, getMetadata, getStreamUrl, testConnection) + provider registry — see `src/providers/types.ts` — depends: none
- [ ] T1.5 `PlaylistImportSource` TypeScript interface (authenticate, listPlaylists, getPlaylistTracks) + registry — see `src/importers/types.ts` — depends: none

## Phase 2: Provider adapters & playback engine
Adapters implement the Phase 1 interface against real backends; the playback
engine only needs the app scaffold. Both can proceed in parallel once Phase 1
lands.

- [ ] T2.1 S3Provider adapter: access key/secret auth, list objects, presigned URL generation (aws4fetch) — see `src/providers/s3` — depends: T1.4
- [ ] T2.2 GoogleDriveProvider adapter: OAuth2+PKCE (react-native-app-auth), list files, download URL — see `src/providers/googledrive` — depends: T1.4
- [ ] T2.3 WebDAV/"other" provider adapter, proving the interface extends beyond S3/Drive — see `src/providers/webdav` — depends: T1.4
- [ ] T2.4 Playback engine: react-native-track-player setup, queue, iOS background audio session, lock-screen/control-center metadata — see `src/playback` — depends: T1.1
- [ ] T2.5 SpotifyImportSource adapter: OAuth (Authorization Code + PKCE), list playlists, fetch tracks — see `src/importers/spotify` — depends: T1.5
- [ ] T2.6 AppleMusicImportSource adapter: MusicKit auth + user token, list playlists, fetch tracks — see `src/importers/applemusic` — depends: T1.5
- [ ] T2.7 Fuzzy track matcher: normalize + compare imported track metadata against local library, confidence score, unmatched list — see `src/importers/matcher.ts` — depends: T1.2

## Phase 3: Settings UI & library sync
Settings needs working adapters + Keychain to configure and test real
credentials; the sync engine needs the DB + adapters to populate the library.
Independent screens/files, can run in parallel.

- [ ] T3.1 Settings screen: add/edit/remove provider credentials, test-connection action, active-source multi-select — see `src/screens/Settings` — depends: T1.3, T2.1, T2.2, T2.3
- [ ] T3.2 Library sync engine: list files from active providers, extract tag metadata, upsert into SQLite — see `src/library/sync.ts` — depends: T1.2, T2.1, T2.2, T2.3

## Phase 4: Core screens
The Spotify/YouTube-Music-style UI, built once there's a populated library
and a working player to drive it. Each screen is its own file tree, safe to
parallelize.

- [ ] T4.1 Library browse (Artists/Albums/Tracks tabs, pull-to-refresh triggers sync) — see `src/screens/Library` — depends: T3.2
- [ ] T4.2 Search screen (SQLite FTS query over local index) — see `src/screens/Search` — depends: T3.2
- [ ] T4.3 Now Playing screen (art, progress, transport controls) — see `src/screens/NowPlaying` — depends: T2.4
- [ ] T4.4 Queue screen (up-next list, reorder) — see `src/screens/Queue` — depends: T2.4
- [ ] T4.5 Playlists (create/edit, add/remove tracks) — see `src/screens/Playlists` — depends: T1.2, T4.1
- [ ] T4.6 Playlist import screen: connect Spotify/Apple Music, pick playlists to import, review/confirm fuzzy-matched + unmatched tracks — see `src/screens/ImportPlaylists` — depends: T2.5, T2.6, T2.7, T4.5

## Phase 5: Offline cache & release polish
Hardening once the core app works end-to-end: reduces re-fetching, handles
real-world failures, and gets the build ready to ship.

- [ ] T5.1 LRU disk cache for streamed audio, backed by provider stream URLs — see `src/playback/cache.ts` — depends: T2.4
- [ ] T5.2 Error/retry handling: expired presigned URLs, Google token refresh, offline state — see `src/providers` — depends: T2.1, T2.2
- [ ] T5.3 App icon, launch screen, TestFlight build config — see `app/` — depends: T1.1
- [ ] T5.4 QA pass: unit tests for provider/importer adapters + sync engine + matcher, manual playback test on device — see `src/providers`, `src/importers`, `src/library` — depends: T4.1, T4.2, T4.3, T4.4, T4.5, T4.6, T5.1, T5.2
