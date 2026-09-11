# Bring-Your-Own-Music Player

## Problem
Spotify/YouTube Music have great streaming UX but only play licensed catalog
content. User owns music files sitting in their own cloud storage (S3 today,
maybe Drive/others later) and wants that same streaming-app experience on
iPhone, without hardcoding one storage backend.

## Goals
- Spotify/YouTube-Music-like iPhone app: browse, search, now-playing, queue,
  playlists, background audio, lock-screen/control-center controls.
- Storage backend is user-configured in Settings, not hardcoded: S3 (access
  key/secret), Google Drive (OAuth), extensible to more providers later.
- Add/edit/remove/test credentials per provider; pick which sources feed the
  library. Credentials encrypted on-device (Keychain), never leave the device.
- Local library index (artist/album/track) built from provider file listings
  + tag metadata, so browse/search work without a backend server.
- Import playlists (track lists, not audio) from existing streaming apps
  (Spotify, Apple Music, YouTube Music) and match each track against the
  local library by metadata, so a user's existing playlists carry over.

## Non-goals
- No backend server, no multi-device account sync (v1) — device-local index.
- No social features (sharing, following, public playlists).
- No transcoding pipeline — plays whatever format AVPlayer supports natively.
- Android — iPhone only for v1 (React Native leaves the door open later).
- No DRM/licensing — user's own files only. Playlist import brings in track
  metadata (title/artist/album/duration) only, never audio, from the
  streaming service — matched tracks must already exist in the user's own
  storage to be playable.

## Options considered
- **RN tooling**: Expo w/ dev client vs bare RN CLI — native modules (track
  player, keychain, background audio) need custom native code either way;
  Expo + EAS dev client gives easier iOS build/config management while still
  allowing native modules via config plugins.
- **Storage abstraction**: direct per-provider SDK calls in UI (simplest,
  couples UI to provider) vs a common `CloudProvider` interface with adapter
  classes (decoupled, easy to add providers) vs a backend proxy aggregating
  providers (most secure, but requires hosting infra — violates no-server
  goal).
- **Credential storage**: AsyncStorage plaintext (insecure) vs iOS Keychain
  via `react-native-keychain` (OS-encrypted, standard for secrets) vs a
  third-party vault (overkill for single-user app).
- **S3 access**: long-lived IAM access key/secret on-device with direct SDK
  calls (matches user's ask, no server needed) vs STS temp credentials via a
  token-broker server (more secure, needs backend — violates no-server goal).
- **Google Drive auth**: OAuth2 + PKCE via `react-native-app-auth`, refresh
  token in Keychain (standard installed-app flow) vs service-account key
  (needs domain-wide delegation, not applicable to personal Drive).
- **Playback engine**: `react-native-track-player` (built for background
  audio, lock-screen, queue, HTTP streaming) vs `expo-av`/`expo-audio`
  (simpler, weaker background/queue support) vs a native Swift module (full
  control, throws away RN cross-platform benefit).
- **Local index/DB**: SQLite (`op-sqlite`) for tracks/albums/playlists/
  provider configs (mature, queryable, supports FTS for search) vs
  Realm/WatermelonDB (heavier to learn, no v1 benefit).
- **Streaming model**: stream directly from a signed URL via HTTP range
  requests (default, no full download) with an LRU disk cache layered on top
  for offline replay, vs download-first-then-play (unnecessary storage use
  for casual listening).
- **Playlist import approach**: scrape each service's web UI (fragile,
  against most ToS) vs official OAuth APIs (Spotify Web API, Apple
  MusicKit, YouTube Data API) — chosen official APIs, each behind a
  `PlaylistImportSource` interface parallel to `CloudProvider`.
- **Track matching**: exact string match only (simple, misses most real
  variants — remaster tags, "feat." ordering) vs normalized fuzzy match
  (strip punctuation/case, compare artist+title+duration tolerance) with a
  manual-confirm step for low-confidence/unmatched tracks — chosen fuzzy +
  confirm, since silent wrong matches are worse than asking the user once.

## Decision
Expo (dev client) + TypeScript. `CloudProvider` interface with S3 and
Google Drive adapters (WebDAV as a third adapter proving extensibility).
Credentials in Keychain via `react-native-keychain`. SQLite local index for
library/search/playlists. `react-native-track-player` for playback. Stream
via presigned/direct URLs with an LRU disk cache for recently played tracks.
`PlaylistImportSource` interface with Spotify/Apple Music/YouTube Music
adapters (OAuth), feeding a fuzzy metadata matcher that resolves imported
tracks against the local library and surfaces unmatched ones for manual fix.

## Risks / open questions
- Long-lived S3 keys on-device are exposed if the phone is compromised —
  mitigate by documenting a read-only, single-bucket IAM policy in the
  Settings help text; accepted risk for v1, not solved in-app.
- Lossless (FLAC) playback support via AVPlayer on iOS is inconsistent —
  verify against the user's actual file formats; no transcoding fallback
  planned for v1.
- Google Drive API pagination/rate limits for large libraries (1000s of
  files) — needs paged listing + background sync, not a blocking initial
  load.
- iOS background execution limits may throttle large background cache
  downloads — only address via `BackgroundTasks` framework if it becomes a
  real problem.
- No multi-device sync of playlists/playback position in v1 — open question
  whether iCloud key-value storage is worth adding later.
- Apple MusicKit requires a Developer Token signed with a private key —
  normally generated server-side; needs a device-local signing approach
  (e.g. sign at build time / on first launch) to stay server-free, or this
  becomes the one place a tiny signing function is unavoidable.
- YouTube has no official "YouTube Music" playlist API — only the general
  YouTube Data API (works for regular YouTube playlists/liked videos, not
  the YT Music app's own playlists) or an unofficial API (ToS risk) — v1
  scope may need to narrow to Spotify + Apple Music only.
- Fuzzy track matching will misfire on live versions, remixes, and
  multi-disc albums — manual-confirm step is required, not optional.
