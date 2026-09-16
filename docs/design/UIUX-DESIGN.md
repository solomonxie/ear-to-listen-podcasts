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
│  ▼ Details/Transcript continue here…     │ ← the WHOLE page scrolls as one; the
├──────────────────────────────────────────┤   artwork and transport scroll away
│  Up Next (12)                       ＋   │ ← pinned; ＋ adds to a playlist
└──────────────────────────────────────────┘
```

Details and Transcript both run far longer than a phone screen, so neither gets its
own scroller inside a fixed frame — a nested box would only ever show a sliver. Up Next
is pinned instead, since it shouldn't be a scroll away past a 40-minute transcript.

**Details** — grouped cards, not one flat list, so "who/what" doesn't blur into "which
file". A row with no value hides itself rather than printing a dash, so a thin-metadata
episode shows a short card instead of a column of blanks.

```
EPISODE          Speaker · Album · Show  (each pushes that page) · Year ·
                 Duration · Track no. · Topics as chips
FILE             Connection · Folder · File · Format · Size ·
                 Downloaded (size, or "Not downloaded")
DATES            Changed on storage · Last synced · Last played · Stopped at
ABOUT THE SHOW   the show's summary, only if there is one
```

**Transcript** — lyric-style. One bright line, everything else dimmed, scrolling itself.

```
┌──────────────────────────────────────────┐
│ ⌁ On-device ▾            3 edits         │ ← one menu: Off / On-device / OpenAI
│ Transcribing 12:00–13:00… · 46% done     │   Whisper, + "Transcribe again…"
├──────────────────────────────────────────┤
│  …so the model runs entirely locally.    │ ← dim
│  Which matters once you pipe in          │ ← BRIGHT = the line being spoken,
│  personal data.                          │   scrolls itself to centre
│  12:14 ✎ edited                          │ ← tap any line to correct it
└──────────────────────────────────────────┘
```

Rules this encodes:
- Off / free-and-offline / paid-and-better is **one** choice, so it's one control, not a
  toggle plus a picker.
- Off by default. Transcribing either spends battery or sends audio somewhere — the
  listener opts in.
- Tap corrects; "play from here" is on the line's context menu. Correcting is the one
  thing only a human can do here, so it gets the primary gesture.
- Every window is saved the moment it lands, so quitting mid-episode keeps what got done
  and coming back resumes at the first hole — never from the top.
- Silence is stored too (as an empty line, hidden), or a music bed would be re-sent to
  the recogniser on every pass, forever.
- Corrections are kept, not just applied: "3 edits" opens a word-level diff, and the
  words the user added are fed back as vocabulary hints so the same misheard name stops
  coming back wrong.

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

**1 · Add a connection → first import.** Credentials usually arrive as a lump of text, so
the top of Add S3 is a paste box that fills the fields as you type (`:` or `=`, any
spelling of the key names) — retyping a 40-character secret on a phone keyboard is where
this goes wrong. Then: Save → Save tests the bucket (scoped to the
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
| Transcript | "Transcribing 12:00–13:00… · 46% done" inline, lines appear as they land | off: "Pick a recogniser above…"; on: "Listening ahead — lines appear as they're recognised." | orange line above the list; on-device needs the Speech permission, Whisper needs an OpenAI key |
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
- "Your corrections are kept — they're used as hints for the new pass." — re-transcribing
  otherwise reads like it throws the user's typing away.
- "Saved on this device, and used as a hint for the rest of the episode" — says what a
  correction is *for*, not just that it saved.
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
