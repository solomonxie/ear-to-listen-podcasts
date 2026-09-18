# Collections — album, speaker, show, playlist, lists

All four are `List(.plain)` pushes off Home. Same spine: a header block, then
`Episodes`.

## Album  `Home/AlbumDetailView.swift`

```
 ‹ Back          Season 3                      ⋯
              ┌─────────────┐
              │   artwork   │      ← tap = photo picker, hold = Remove
              │    168pt    │        Picture. No Edit sheet to fix a cover
              └─────────────┘        that came out of a stray MP3 tag
                 Season 3            ← title
              Andrew Huberman        ← accent, tappable: embedded speaker
                                       tags are often an uploader name
           2026 · 12 episodes · 7h 41m
              ↑ album's own year, skipped when unset
             [[ ▶ Play latest ]]
 What this collection is, three lines of it before it clips —
 tap to open the rest.                        ← notes, only if any
 Details                                  ⌄   ← one row, closed
 ┌ Details, open ──────────────────────────┐
 │ Episodes             12                 │
 │ Total length         7h 41m             │
 │ Episode years        2024–2026          │ ← when they differ from the
 │ Folder               bible-audio/2026   │   album's own year
 │ Downloaded           3 of 12            │ ← only when all share one folder
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

 ⋯ menu   ✨ Analyze with AI…        ·  disabled with 0 transcripts
```

**The header is the editor.** Name, speaker, year, language and notes are live
fields in it; the picture is its own control. Nothing to open, nothing to save:

```
 ┌─────────────────────────────────────────┐
 │ Speaker    Andrew Huberman           ›  │ ← › still pushes their page
 │ Year       2026                         │
 │ Language   English ▾                    │
 │ Notes      What this collection is      │
 └─────────────────────────────────────────┘
   leave a field ─▶ save        closing the page counts too
   a sync lands mid-edit ─▶ the field being typed in is left alone
```

The header answers the four things worth knowing before you press play —
picture, name, voice, how much of it there is — and nothing else. The counts
and paths are facts you look up once and never again, so they fold into one
row rather than standing between the header and the episodes.

An album carries its **own year**. Every episode in it falls back to that year, shown in the
episode's own Year row as the placeholder `2026 · from album` — typing over it
overrides it for that episode only.

## Speaker  `Home/SpeakerDetailView.swift`

```
 ‹ Back        Andrew Huberman             Edit
 ◯ 96pt avatar        ← tap = Edit. Auto-filled from episode artwork when
                        unset, once, never over a photo the listener chose
 Neuroscientist at Stanford…                    bio, secondary
 Add a bio                                      ← accent, when there is none
 🌐 Set the language they speak                 ← accent, when unset: it's
                                                  what decides transcription
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

## No edit sheets

Albums and speakers are edited where they are read. Both pages used to carry an
Edit button onto a second copy of themselves — a screen transition, a form to
re-read and a Save to remember, for changing one word already on screen.

```
✗  ‹ Back   Andrew Huberman   Edit  →  Cancel  Edit Speaker  Save
✓  ‹ Back   Andrew Huberman         the page itself, fields live
```

Two things the sheets did that the pages now do inline: changing an album's
speaker re-points every episode in it, not just the album; and a speaker with no
photo takes one from their own episodes' artwork on first visit, never over one
that was chosen.

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
