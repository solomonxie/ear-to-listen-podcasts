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
                 Season 3            ← title, a live field
           2026 · 12 episodes · 7h 41m
              ↑ album's own year, skipped when unset
             [[ ▶ Play latest ]]
 ┌ DETAILS ────────────────────────────────┐
 │ Speaker            Andrew Huberman      │ ← tap the value, type
 │ Year                        Add a year  │ ← gray = empty, still tappable
 │ Language      Inherit (automatic)    ⌄  │
 │ Notes                                   │ ← label above: a sentence needs
 │   What this collection is               │   the width, not a right column
 │ ⊙ Open Andrew Huberman's page        ›  │ ← the ONLY › on the page, and
 └─────────────────────────────────────────┘   it says where it goes
 ┌ PROFILE ────────────────────────────────┐
 │ The long read — what this collection    │ ← empty until you write it or
 │ is, how it's put together, who it's     │   ⋯ → Describe this collection
 │ for…                                    │   fills it in
 └─────────────────────────────────────────┘
 ┌ STATS ──────────────────────────────────┐
 │ Episodes             12                 │ ← read-only, and always open:
 │ Total length         7h 41m             │   a fold on eight short rows
 │ Episode years        2024–2026          │   hides them to save nothing
 │ Folder               bible-audio/2026   │ ← only when all share one folder
 │ Downloaded           3 of 12            │
 │ Fully transcribed    5 of 12            │ ← what AI analysis can read
 │ Size on storage      412 MB             │
 │ Edited               Sep 16, 2026       │
 └─────────────────────────────────────────┘
 ┌ BOOKMARKS ──────────────────────────────┐  above the episodes on purpose:
 │ 12:14  "…pipe in personal data"     ✎   │  a hand-made mark outranks the
 └─────────────────────────────────────────┘  twentieth row of a folder
 ┌ EPISODES ───────────────────────────────┐
 │ ▢ Sleep Toolkit — Part 2                │  full TrackRow, album = queue
 └─────────────────────────────────────────┘

 ⋯ menu   ✨ Analyze with AI…        ·  disabled with 0 transcripts
          ≡ Describe this collection… ·  always, once there are episodes
```

**Edited in place, as ordinary form rows.** Label left, value right, tap the
value and type. Nothing to open, nothing to save:

```
   leave a field ─▶ save        closing the page counts too
   a sync lands mid-edit ─▶ the field being typed in is left alone
```

**Three glyphs, three meanings, never mixed:** a plain value is typeable, `⌄`
is a picker, `›` goes somewhere. Opening the speaker's page is therefore its own
row — when it shared the Speaker field's row, that row carried two chevrons
pointing at two different things and read as neither.

The header above stays down to picture, name, how much there is, and Play —
what you want before pressing play. Everything else is a row you read rather
than decode.

An album carries its **own year**. Every episode in it falls back to that year, shown in the
episode's own Year row as the placeholder `2026 · from album` — typing over it
overrides it for that episode only.

## Speaker  `Home/SpeakerDetailView.swift`

Same spine as the album: header, `Details` as ordinary form rows, then the
long read, then the lists.

```
 ‹ Back        Andrew Huberman                 ⋯
 ◯ 96pt avatar        ← tap = photo picker, hold = Remove Photo. Auto-filled
                        from episode artwork when unset, once, never over a
                        photo the listener chose
 Andrew Huberman                                ← name, a live field
 Huberman Lab                                   show names, caption
 ┌ DETAILS ────────────────────────────────┐
 │ Bio          Neuroscientist and…        │ ← tap the value, type
 │ Known for    sleep, dopamine, focus     │
 │ Language     English                 ⌄  │ ← decides transcription; the
 │ Background                              │   usual cause of a nonsense
 │   Professor at Stanford…                │   transcript is this being wrong
 └─────────────────────────────────────────┘
 ┌ PROFILE ────────────────────────────────┐
 │ A few paragraphs on who they are and    │ ← the part worth reading, and
 │ what this collection of their episodes  │   still just a text field
 │ covers…                                 │
 └─────────────────────────────────────────┘
 ┌ ALBUMS ─────────────────────────────────┐
 │ ▢ Season 3                           ›  │   "No albums yet" when none
 ┌ EPISODES ───────────────────────────────┐

 ⋯ menu   ✨ Build profile with AI…   · disabled with nothing to read
```

**An MP3 tag holds a name, and that's all.** Everything else here starts empty,
which is why the page has a way to fill itself in — see *Profiles from
metadata* below.

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

## Profiles from metadata

`⋯ → Build profile with AI` (speaker) and `⋯ → Describe this collection…`
(album) fill in the fields above from what the library already holds — names,
episode titles, years, collections, folders. **No audio, no transcripts**, so
both work on a bucket where nothing has been transcribed yet. That's the whole
reason they're separate from the album's `Analyze with AI…`, which reads
finished transcripts to rewrite each *episode's* title and is disabled without
them.

```
 ┌ Speaker Profile ──────────── Cancel · Analyze ┐
 │ Episode titles       37                       │ ← what it's about to read,
 │ Collections           2                       │   before anything is spent
 │ Shows                 1                       │
 │                                               │
 │ Reads only what's on this page… Anything it   │
 │ says about a person comes from what the model │
 │ already knows, so check it before you keep it.│
 └───────────────────────────────────────────────┘
                      ↓ Analyze
 ┌ Speaker Profile ─────────────── Cancel · Apply ┐
 │ BIO                                            │
 │  ✓ Neuroscientist and podcaster                │ ← on, and refusable
 │    empty now                                   │
 │ KNOWN FOR                                      │
 │  ✓ sleep, dopamine, focus                      │
 │    ~~what they talk about~~                    │ ← what it replaces
 └────────────────────────────────────────────────┘
```

Two rules carried over from `AlbumAnalysisView`: every field arrives switched
on but **individually refusable**, and applying writes a `LocalBackups`
snapshot first, since one tap can overwrite several fields at once.

**It is allowed to know nothing.** The prompt asks for null rather than a guess
on anything it can't place, and an empty or blank answer decodes as "no
suggestion" rather than as a blank field to write over a hand-typed one.
