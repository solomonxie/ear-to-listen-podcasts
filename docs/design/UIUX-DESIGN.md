# Bring-Your-Own-Podcasts — UI/UX Design

Screens, flows, states and copy as actually built. `DESIGN.md` covers the product
decision and options; the per-folder `README.md`s cover code structure. Reusable
preferences extracted from this app live in the `uiux` skill
(`my-mobile-design-guideline.bring-your-own-podcasts.md`) — this file is the concrete
design, not the general rules.


## Navigation model

One scrollable page, not a tab bar. Sections stack; everything else is a push or a
sheet over it.

```
ContentView → NavigationStack
└── HomeView  (one page, scrolls)
    ├── 🔍 search                     ← filters shelves in place
    ├── shelves: Continue Listening · Albums · Speakers · Shows · Topics ·
    │            Playlists · Favorites · Browse by Year · Downloaded
    ├── ── Remote ─────────── +       ← section, not a tab
    │      connection rows → RemoteBrowserView (push, recursive)
    │      "Sync queue: N pending"   → SyncQueueView (sheet)
    ├── ── Settings ───────────       ← section, not a tab
    └── ▶ MiniPlayerBar (docked)      → RealPlayerView (sheet)

pushes : RemoteBrowserView · SpeakerDetailView · AlbumDetailView · ShowDetailView ·
         PlaylistDetailView
sheets : RealPlayerView · SyncQueueView · AddS3ProviderView · AddAiKeyView ·
         DownloadsView · SpeakerEditView · AddToPlaylistSheet · AddTracksToPlaylistView
```

Rules this encodes:
- Now Playing is a sheet + a docked mini player, never its own tab.
- Anything naming another entity is tappable and opens it (speaker, album, show).
- No screen exists only to host controls another level already carries.


## Screens

### Home

Horizontal shelves of cards. Card titles are one line — two-line titles give cards in
the same shelf different heights and the progress bars stop aligning.

Shelves are real data, not recommendations: there is no algorithmic shelf, because
there is no algorithm. "Continue Listening" is playback history; "Downloaded" is what
`AudioCache` actually holds.

### Remote browser

Real folder browsing, one level at a time, the same screen pushing itself per
subfolder. No separate detail screen, no per-level difference.

```
┌─────────────────────────────────────────┐
│ ‹ Back        slmx-archives2        (⋯) │
├─────────────────────────────────────────┤
│ 📁  bible-audio                     ›   │ → push, same screen, deeper prefix
│ 〰  ep-004.mp3              24.1 MB  ⓘ  │ → plays; ⓘ opens file info
├─────────────────────────────────────────┤
│ 361 episodes synced · 12.14 GB  ⟳ Sync… │ ← footer scoped to THIS folder
└─────────────────────────────────────────┘
```

The `⋯` menu is identical at every depth:

```
Sync: Manual                    ▸   ← submenu carrying the current value
Last synced: 9 hours ago
Sync Now
Sync Queue                      ☰
──────────
Delete Connection               🗑  ← destructive, last
```

Both the listing and the footer are built from already-synced local rows
(`TrackStore.directoryListing` / `.stats`). Browsing never calls the provider.

### Sync queue

Global across connections, reached from the Remote section's status line or any
connection's `⋯`.

```
Queue (1,284)                  ⏸  ⋯   ⏸ = pause/play icon (not a "Paused" switch)
┌──────────────────────────────────┐   ⋯ = Speed: N at a time · Clear Synced ·
│ ep-004.mp3  archives  ⟳ running  │       Clear Queue
│ ep-005.mp3  archives    Waiting  │   ▲ unfinished, in queued order
│ ep-002.mp3  archives  ↻ Retry    │   │ failed stays up: it needs a decision
│   403 SignatureDoesNotMatch      │   ▼ error inline on the row
├──────────────────────────────────┤
│ ep-003.mp3  archives         ✓   │   ▲ finished, newest completed first
├──────────────────────────────────┤
│         Load 1,184 more…         │   ← 100 per page
└──────────────────────────────────┘
```

Header count and the "N pending" summary come from `COUNT` queries, never off the
visible page.

### Now playing

```
┌──────────────────────────────────────────┐
│             [ artwork ]                  │ ← deterministic colour/icon from track id
│             Sleep Toolkit                │
│  Speaker: Huberman · Album: Season 3     │ ← one line; each half pushes that page
│  ├──────────●───────────────────────┤    │ ← custom scrubber, tap anywhere to seek
│      ⏮       ⏸       ⏭                   │
│  [ Details | Transcript ]                │
│  Up Next (12)                       ＋   │ ← ＋ adds current track to a playlist
└──────────────────────────────────────────┘
```

### Playlists

Two entry points, because they answer different questions:

```
"I'm listening to this, keep it"  → Now Playing ＋ → pick/create a playlist
"I'm building this playlist"      → Playlist ＋    → browse Speakers | Albums |
                                                     Playlists, ＋/✓ toggle in place
```

### Speaker / Album detail

Speaker: avatar (photo or placeholder), bio, shows, albums, episodes, `Edit`.
Album: art, tappable speaker line (opens a correction alert), episode list, Play latest.

Both exist largely to make wrong synced metadata fixable — see flow 5.

### Settings

Sections: Local Folders · Storage (Downloaded Episodes) · AI Keys · Sync & Backup ·
Reset Demo Data. Each carries a short hint under its heading, not a paragraph at the
bottom.


## Flows

**1 · Add a connection → first import.** Add S3 → Save tests the bucket (scoped to the
prefix) and only persists on success → the whole bucket is listed recursively and every
audio file is queued → progress is visible in the sync queue immediately. This is the
one time the app scans without being asked.

**2 · Browse → play.** Open connection → local listing → tap a file → plays (importing
it first if somehow unknown) → sheet opens. A cache miss streams at once while a copy
downloads in the background.

**3 · Keeping up to date.** Only three things go to the network after step 1: an
explicit "Sync Now", a scheduled tick when a frequency is set, and playing an episode.
A connection on Manual fetches nothing on its own — not even file headers.

**4 · Add to a playlist.** Either direction above; creating a playlist is inline.

**5 · Fix wrong metadata.** Embedded tags are often a generic uploader name. Speaker →
Edit renames; Album → tap the speaker line reassigns to a *different* speaker, which
repoints every track that carries its own copy. Photo/bio edits survive backup.

**6 · Backup / restore.** Export writes a zip (`snapshot.json` + `photos/`); Backup
uploads the same bytes to a fixed key in the active bucket. Restore merges: inserts only
what's missing, matches tracks by (connection, file path) and speakers by name, and
reports what didn't match rather than dropping it.

**7 · Free up space.** Settings → Downloaded Episodes → swipe to remove. Drops only the
local copy; the episode stays synced and re-downloads next play.


## States

| Screen | Loading | Empty | Error / offline |
|---|---|---|---|
| Remote browser | spinner in place of the list; footer held back too | "No episodes synced yet." | listing read fails → orange line above the list |
| Sync queue | — | "Nothing queued. Sync a folder from a remote source to add files here." | failed job shows its provider error inline + Retry |
| Now playing | — | "Nothing playing" | "You're offline. Connect to the internet to stream this track." |
| Downloads | spinner | "No downloaded episodes yet. Anything you play is saved here automatically." | — |
| Add S3 / Add AI key | inline "Testing…" on Save | — | inline red line, never an alert |

Cross-cutting:
- A track missing from the last listing is badged **Missing**, never deleted.
- Sync in progress shows inline on the stats footer, not as its own row.
- The stats footer is withheld until its list resolves, so stats never float above an
  empty list.


## Copy that carries design intent

- "Sync only fetches metadata — episodes download when you listen." — a bucket-backed
  library otherwise reads like it is about to copy everything.
- "Manual (no auto sync)" — and it means it.
- "Stored only in this device's Keychain — we never see it or send it anywhere
  ourselves…" — API keys are sensitive to type in blind.
- "Keys never leave this device, including in backups."
- "Folder (key prefix)" — not the raw S3 term.
- "N items need a sync first" on restore — better than silently dropping them.
- "Added X, Y missing, Z files found." after a manual sync.


## Open questions

- **Add-time import vs Manual.** Adding a connection imports the whole bucket even
  though the default frequency is Manual. Deliberate, but it does contradict what
  "Manual" implies. Options: leave it, gate it on frequency, or prompt "Import all now?".
- **Never-synced folders look empty.** Local-only browsing means a folder whose files
  were never imported shows "No episodes synced yet." rather than its real contents.
- **Non-audio files are invisible.** They were never imported, so nothing local knows
  about them. Previously the live listing showed them.
- **No live-refresh affordance.** "Sync Now" refreshes the whole connection; there's no
  per-folder pull-to-refresh that opts into a live listing.
