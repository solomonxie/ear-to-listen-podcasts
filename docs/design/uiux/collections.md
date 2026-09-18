# Collections — album, speaker, show, playlist, lists

All four are `List(.plain)` pushes off Home. Same spine: a header block, then
`Episodes`.

## Album  `Home/AlbumDetailView.swift`

```
 ‹ Back          Season 3                      ⋯
 ┌─────────────────────────────────────────┐
 │            [ artwork 160pt ]            │
 └─────────────────────────────────────────┘
 Andrew Huberman                  12 episodes
 ↑ tappable — embedded speaker tags are often a shared uploader name
 Set speaker                      ← secondary, when there is none
 [[ ▶ Play latest ]]
 ┌ NOTES ──────────────────────────────────┐  (only if any)
 ┌ DETAILS ────────────────────────────────┐
 │ Episodes             12                 │
 │ Total length         7h 41m             │
 │ Years                2024–2026          │
 │ Folder               bible-audio/2026   │ ← only when all share one
 │ Downloaded           3 of 12            │
 │ Fully transcribed    5 of 12            │ ← what AI analysis can read
 │ Size on storage      412 MB             │
 │ Details edited       Sep 16, 2026       │
 └─────────────────────────────────────────┘
 ┌ BOOKMARKS ──────────────────────────────┐  above the episodes on purpose:
 │ 12:14  "…pipe in personal data"     ✎   │  a hand-made mark outranks the
 └─────────────────────────────────────────┘  twentieth row of a folder
 ┌ EPISODES ───────────────────────────────┐
 │ ▢ Sleep Toolkit — Part 2                │  full TrackRow, album = queue
 └─────────────────────────────────────────┘

 ⋯ menu   ✎ Edit Album…
          ✨ Analyze with AI…        ·  disabled with 0 transcripts
```

## Speaker  `Home/SpeakerDetailView.swift`

```
 ‹ Back        Andrew Huberman             Edit
 ◯ 96pt avatar        ← auto-filled from episode artwork when unset, once,
                        and never over a photo the listener chose
 Neuroscientist at Stanford…                    bio, secondary
 🌐 English                                     ← decides transcription
 🌐 Language not set — tap Edit to choose
 Huberman Lab                                   show names, caption
 ┌ ALBUMS ─────────────────────────────────┐
 │ ▢ Season 3                           ›  │   "No albums yet" when none
 ┌ EPISODES ───────────────────────────────┐
```

## Show  `Home/ShowDetailView.swift`

```
 ‹ Back         Huberman Lab
 ┌ 🎙 160pt gradient tile ──────────────────┐
 Summary text…
 Andrew Huberman                   [ Save ] ← flips to [ Saved ]
 [[ ▶ Play latest ]]
 ┌ EPISODES ───────────────────────────────┐
```

## Playlist  `Playlists/PlaylistDetailView.swift`

```
 ‹ Back      Night listening               ⊕  → Add Episodes sheet
 ┌ rows ───────────────────────────────────┐
 empty  ┌──────────────────────────────┐
        │   🎙⃠  No episodes yet        │
        └──────────────────────────────┘
```

Two entry points, because they answer different questions:

```
 "I'm listening to this, keep it"  → Now Playing ＋ → pick / create
 "I'm building this playlist"      → Playlist ⊕ → browse and tick
```

```
        Add Episodes                    Done
 [ SPEAKERS | Albums | Playlists ]   ← segmented category
 ▢ Andrew Huberman                 ›
     → list of that speaker's episodes, ＋ / ✓ toggling in place
```

## Year / topic list  `Home/EpisodeListView.swift`

```
 ‹ Back            2026                      ← or the topic name
 ▢ Sleep Toolkit — Part 2                    plain TrackRows
   …/ep-004.mp3 · 41 min
 empty   🎙⃠  No episodes yet
```

## Edit sheets

```
 Cancel        Edit Album             Save·     · while name empty
 ▢ artwork (tap) — long-press → Remove Artwork !
 ┌ ALBUM ──────────────────────────────────┐
 │ Name                                    │
 │ Speaker                                 │
 │ Spoken language ▾                       │
 ├ NOTES ──────────────────────────────────┤
 │ What this collection is                 │
 └─────────────────────────────────────────┘
 Changing the speaker re-points every episode in this album,
 not just the album itself.

 Cancel       Edit Speaker            Save·
 ◯ photo (tap)   [ ✨ Use episode artwork ]   ⟳ while searching
 ┌ DETAILS ────────────────────────────────┐
 │ Name · Bio · Language ▾ (Not set first) │
 └─────────────────────────────────────────┘
 Used to transcribe this speaker's episodes. Recognizers have to be
 told which language to expect — they can't work it out, and the wrong
 one returns confident nonsense rather than failing.
```

## Analyze with AI  `Home/AlbumAnalysisView.swift`

One pass over the album, reading **only transcripts already on the phone**.

```
 Cancel        Analyze Album          Analyze / Apply
 ┌─────────────────────────────────────────┐
 │ Fully transcribed        5              │
 │ Skipped                  7              │
 │ ⟳ Reading 5 transcripts…                │
 │ Reads only transcripts already stored on│
 │ this phone — nothing is downloaded and  │
 │ nothing is transcribed. Episodes that   │
 │ aren't finished yet are left exactly as │
 │ they are.                               │
 ├ ALBUM ──────────────────────────────────┤
 │ ─● Season 3 → Sleep & Recovery          │
 ├ EPISODES ───────────────────────────────┤
 │ ─● ~~ep-004~~ Sleep Toolkit — Part 2    │ each switched on, individually
 │    …/bible-audio/2026/ep-004.mp3        │ refusable
 ├ LEFT ALONE (7) ─────────────────────────┤
 └─────────────────────────────────────────┘
 Analyze disabled with nothing ready · Apply disabled with nothing accepted ·
 nothing is written until Apply
```
