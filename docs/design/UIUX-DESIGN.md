# Bring-Your-Own-Podcasts — UI/UX Design

**Every screen is drawn in `uiux/` — start there.** This file carries the rules,
flows and copy behind those drawings; where the two disagree, `uiux/` is current.

Screens, flows, states and copy as actually built. `DESIGN.md` covers the product
decision and options; the per-folder `README.md`s cover code structure. Reusable
preferences extracted from this app live in the `uiux` skill
(`my-mobile-design-guideline.ear-to-listen-podcasts.md`) — this file is the concrete
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
    │      "Queue (N)" pill          → SyncQueueView (sheet)
    ├── ── Settings ───────────       ← section, not a tab
    └── ▶ MiniPlayerBar (docked)      → RealPlayerView (sheet)

pushes : RemoteBrowserView · SpeakerDetailView · AlbumDetailView · ShowDetailView ·
         PlaylistDetailView
sheets : RealPlayerView · SyncQueueView · AddCloudSourceView · AddAiKeyView ·
         DownloadsView · SpeakerEditView · AddToPlaylistSheet · AddTracksToPlaylistView
```

Rules this encodes:
- Now Playing is a sheet + a docked mini player, never its own tab.
- Anything naming another entity is tappable and opens it (speaker, album, show).
- No screen exists only to host controls another level already carries.


## Screens

### Every episode row

Title, then the file path under it, everywhere an episode is listed — rows, shelf cards,
Up Next, the mini player (filename only; the bar is too narrow for a path), Now Playing.
Not a fallback for missing titles: whole folders routinely share one embedded title tag,
and then the path is the only thing telling two episodes apart. Truncated at the head so
the filename — the telling end — survives. Long-press any row for `Edit Details`.

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
│ 361 episodes synced · 12.14 GB  ⟳ Sync… │ ← footer scoped to THIS folder;
└─────────────────────────────────────────┘   "Sync…" taps through to the queue
```

The `⋯` menu is identical at every depth:

```
Last synced: 9 hours ago            ← text, not a control
Queue                           ☰
──────────
Delete Connection               🗑  ← destructive, last
```

Sync Now and the frequency picker are *not* here: they're decisions about a
connection, so they sit on the source's own row in the Remote section.

The listing is **live**: each level is one delimited `listObjectsV2` per folder
(`CloudProvider.listDirectory`), so a file uploaded a minute ago is there before
any sync runs. Offline or on error it falls back to already-synced local rows and
says "Showing last synced" in the footer. The footer's numbers stay local — they
report what this device has synced, which is a different question.

### Queue

Global across connections, reached from the Remote section's status line or any
connection's `⋯`.

```
Queue (87/100)                 ⏸  ⋯   ⏸ = pause/play icon (not a "Paused" switch)
┌──────────────────────────────────┐   ⋯ = Speed: N at a time · Clear Synced ·
│ ep-004.mp3  archives Reading tags│       Clear Queue
│ ep-005.mp3  archives    Waiting  │   ▲ unfinished, in queued order
│ ep-002.mp3  archives  ↻ Retry    │   │ failed stays up: it needs a decision
│   403 SignatureDoesNotMatch      │   ▼ error inline on the row
├──────────────────────────────────┤
│ ep-003.mp3  archives         ✓   │   ▲ finished, newest completed first
├──────────────────────────────────┤
│         Load 1,184 more…         │   ← 100 per page
└──────────────────────────────────┘
```

A running row says what it's doing — Reading tags · Asking AI · Saving to library
— since a slow tag read off a remote file and a slow AI call look identical behind
one spinner.

**Paused means paused.** Not just "stop working the list": nothing new is accepted
either, a whole-bucket pass refuses to start, and the background schedule sits out
too. One control, one meaning.

**A ceiling of 100 unfinished jobs.** A bucket with thousands of files would
otherwise queue every one of them the moment it's added — hours of work nobody
asked for, in a list nobody can read. Listing stops at the ceiling with a banner
saying so, then the queue tops itself back up: when it drains empty, that
connection is re-listed and the next hundred go in, repeating until the bucket
is done. The ceiling caps what's *waiting*, not what gets imported. The header
counts unfinished against that ceiling, not the total, so a pile of finished
rows doesn't read as nearly full.

**Listing and importing are separate.** A whole-bucket pass lists, queues and
returns in seconds; the queue does the importing at the speed set here. That's
why "Speed: N at a time" applies to a "Sync Now" too, and why a large bucket no
longer freezes the button that started it.

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
│  ▼ details cards, then the transcript    │ ← the WHOLE page scrolls as one; the
├──────────────────────────────────────────┤   artwork and transport scroll away
│  Up Next (12)                       ＋   │ ← pinned; ＋ adds to a playlist
└──────────────────────────────────────────┘
```

One page, no tabs. Details and the transcript are read together — you check who the
speaker is *because* of a line you just read — and a segmented control between them was
a tab bar for two halves of one thing, costing a tap and the scroll position each way.
Neither gets its own scroller inside a fixed frame either: both run far longer than a
phone screen, and a nested box would only ever show a sliver. Up Next is pinned instead,
since it shouldn't be a scroll away past a 40-minute transcript.

**Details** — grouped cards, not one flat list, so "who/what" doesn't blur into "which
file". A row with no value hides itself rather than printing a dash, so a thin-metadata
episode shows a short card instead of a column of blanks.

```
EPISODE          Speaker · Album · Show  (each pushes that page) · Year ·
                 Duration · Track no. · Topics as chips · Edit Details
NOTES            free text, only if there is any
FILE             Connection · Folder · File · Format · Size ·
                 Downloaded (size, or "Not downloaded")
DATES            Changed on storage · Last synced · Last played ·
                 Details edited · Stopped at
ABOUT THE SHOW   the show's summary, only if there is one
```

**Transcript** — lyric-style. One bright line, everything else dimmed, scrolling itself.

```
┌──────────────────────────────────────────┐
│ TRANSCRIPT                        3 edits│
│ [📱 On-device] [✨ AI] [⌖ Follow]        │ ← one button per recogniser;
│ Transcribing the whole episode · 46%     │   each does the whole episode
├──────────────────────────────────────────┤
│  …so the model runs entirely locally.    │ ← dim
│  Which matters once you pipe in          │ ← BRIGHT = the line being spoken,
│  personal data.                          │   scrolls itself to centre
│  12:14 ✎ edited                          │ ← tap any line to correct it
└──────────────────────────────────────────┘
```

Rules this encodes:
- Every option is in view, in a fixed place. They're the ones you reach for while
  listening, and a menu made each one a tap-and-hunt — worse, it hid whether anything
  was running at all. The spoken language is a menu, and it sits with the episode's
  own details, since it describes the episode rather than this pass.
- A pass runs whole and out of sight: a percentage while it works, the text all at
  once when it's done. Live transcription rewrote lines under the reader and
  recognised the same audio several times over as the playhead moved.
- Options the switch governs are dimmed rather than hidden, so the section doesn't reflow
  under your thumb as you flip it.
- **Off for every episode**, and not remembered between them — there is no global "do
  this always" switch either, for the same reason. Transcribing spends battery or money;
  a preference that sticks means opening any episode quietly starts spending on it. Whatever was transcribed before — and any transcript file sitting beside the audio —
  still shows with the switch off, so nothing is lost by asking each time.
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

Album: artwork, tappable speaker line, notes, a Details block (episodes · total length ·
years · shared folder · downloaded N of M · **fully transcribed N of M** · size · details
edited), episode list, Play latest. The transcribed count is there because it's exactly
what the batch pass below can read, said before you open it.

`⋯` menu: `Edit Album…` (name, speaker, notes, artwork — speaker writes through to every
episode) and `Analyze with AI…`.

**Analyze with AI** — one pass over the whole album, reading only transcripts already
stored on the phone: nothing is downloaded and nothing is transcribed to run it, and
episodes without a finished transcript are listed as "Left alone" rather than guessed at.
Results arrive as a review list — new title over the struck-through old one, path
underneath — each switched on but individually refusable, plus the album's own
name/speaker/notes. Nothing is written until `Apply`.

Both pages exist largely to make wrong synced metadata fixable — see flow 5.

### Episode edit

Reached from `Edit Details` (Now Playing toolbar, the Details card, or a long-press on any
row). Artwork picker on top, then title, speaker, album, show, year, track no., notes, and
the file path shown read-only — the one field that isn't editable, because it's what the
file actually is.

`Suggest with AI` fills the fields in from the episode's own transcript; a field it can't
improve is left alone rather than blanked. Disabled until that transcript is *complete*,
with the reason in its place ("Only 40% of this episode is transcribed…") — a partial
transcript names the whole episode after its first ten minutes, and a confident wrong
title is worse than the generic tag it replaced. Over-long transcripts are sampled evenly
across the episode, never cut off at the front.
Nothing is written until `Save`, and a saved edit outranks the embedded tags from then on
— sync only reads tags for files the library doesn't know yet.

### Settings

Sections: Sync & Backup · AI Keys · Language (last: set once, never
thought about again). Each
carries a short hint under its heading, not a paragraph at the bottom. Row labels say
what the row does, not what it is: "Upload from Files", not "Add a Folder".

Settings holds only what has nowhere better to live. A control belongs beside the thing
it acts on, not in a settings list that grows a section per feature:

- **Adding episodes** isn't here at all — it's `Upload from Files` in the bucket folder
  you want them in (remote.md), so an episode is backed up and on every device instead of
  readable only on the phone that picked it. Sources picked before that still appear, only
  when there are any, to switch off or delete.
- **Downloaded episodes** are managed from the `Downloaded` shelf's own `More` button on
  Home, not a Storage section repeating what the shelf already shows.
- **Backing app data up to a bucket** is a toggle on that connection's row in Remote,
  next to `Sync Now` and its frequency — same bucket, same question. An ordinary switch
  on its own row: pressed into the pill row beside two buttons, it read as a third button.
Tapping an AI key opens its own page: every call made with that key, newest first, with
the model, tokens in and out, and an estimated cost, and the prompt and reply behind a
tap. A request count is the only thing a key can otherwise show, and it answers none of
the questions people actually have — what is this spending money on, why did the bill
jump, is this key failing? Failures are kept too, with the vendor's own words, since a
key that's been refused all week is the thing the page exists to make visible. The cost
says "estimated" everywhere it appears: it's list price × tokens, and the vendor's
invoice is the only real number.

Backup destinations are one switch each and nothing else — on means every change goes
there, off means none do. iCloud comes first: it's the only one with nothing to set up.
Flipping it on backs up immediately, so "did that work?" is answered by the row rather
than by a `Sync Now` button beside it. When the folder can't be used, the row says which
of the four causes it is, in place of the location line, and only the one the listener
can fix carries directions — spelled out in full, since the setting is four levels down
under their own name:

```
 iCloud Drive                                         ●──
 Files / iCloud Drive / Ear to Listen · Last: Sep 16

 iCloud Drive                                         ──○   ← disabled
 iCloud Drive is off on this device.
 Settings → your name → iCloud → iCloud Drive → turn on     ← accent, here only

 iCloud Drive                                         ──○
 This build of the app isn't signed for iCloud.             ← no second line
```

No sample library ships: a fresh install is an empty library, because sample content
sitting in the same shelves as synced content can't be told apart from it. The seeder and
its clips stay in the repo (`DemoData/`) for manual testing only.


## Flows

**0 · Folder, not prefix.** A connection points at a folder inside the bucket, and
only ever a folder: a bare `pod` would quietly also match `podcasts-old/`. The
field is "Folder path", empty means the whole bucket, and the trailing `/` is added
rather than asked for (`S3FolderPath.normalized`, applied on save, on paste, and on
read — so connections stored before this start behaving like folders too).

**1 · Add a connection → first import.** Credentials usually arrive as a lump of text, and
retyping a 40-character secret on a phone keyboard is where this goes wrong — so the
"S3 Bucket" section header carries a small inline button, `S3 Bucket (paste info to add)`.
Tapping it swaps the four fields for a paste box in place (no permanent block at the top
of the sheet); one paste parses it (`:` or `=`, any spelling of the key names) and snaps
straight back to the now-filled fields, so what got picked up is visible and editable.
`(back to fields)` exits without pasting. Then: Save → Save tests the bucket (scoped to the
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

**6 · Backup / restore.** Export writes a zip (`snapshot.json` + `photos/`); the same
bytes go to one always-overwritten file in iCloud Drive and to a fixed key in the active
bucket.
Restore merges: inserts only what's missing, matches tracks by (connection, file path)
and speakers by name, and reports what didn't match rather than dropping it.

**7a · Where did the AI spend go?** Settings → AI Keys → tap the key → the last 100
calls with tokens and estimated cost, tap one to read the prompt and the reply.

**7 · Delete the app, reinstall it.** First launch finds an empty library, pulls the
newest iCloud archive back and applies it without asking — there's nothing to overwrite,
and no context yet for a "restore from backup?" dialog. Playlist order, hand edits and
transcripts name episodes that haven't synced yet, so they're reported as waiting and
re-applied automatically after each sync until none are left.

**8 · Free up space.** Home → Downloaded → More → swipe to remove. Drops only the local
copy; the episode stays synced and re-downloads next play.


## States

| Screen | Loading | Empty | Error / offline |
|---|---|---|---|
| Remote browser | spinner in place of the list; footer held back too | "No episodes synced yet." | listing read fails → orange line above the list |
| Queue | — | "Nothing queued. Sync a folder from a remote source to add files here." | failed job shows its provider error inline + Retry |
| Now playing | — | "Nothing playing" | "You're offline. Connect to the internet to stream this track." |
| Transcript | "Transcribing 12:00–13:00… · 46% done" inline, lines appear as they land | off: "Off for this episode — switch it on above…"; on: "Listening ahead — lines appear as they're recognised." | orange line above the list; on-device needs the Speech permission, Whisper needs an OpenAI key |
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
