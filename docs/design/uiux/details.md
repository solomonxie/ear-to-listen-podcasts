# Episode details & edit

`Sources/Screens/Player/EpisodeDetailsPane.swift` — grouped cards under the
transport, so "who/what" never blurs into "which file". The EPISODE card *is*
the editor: every field is live, shows even when empty, and commits when it
loses focus.

One label column, values against it. Labels left and values right put a hand's
width of nothing between `Size` and `24.1 MB`, and a card of short values read
as two unrelated lists rather than rows:

```
✗  Size                          24.1 MB      ✓  Size        24.1 MB
   Format                            MP3         Format      MP3
```

```
 ┌ EPISODE ───────────────────────────────────┐
 │ ▢  Sleep Toolkit — Part 2                  │ ← tap ▢ = photo picker
 │ 64 (long-press ▢ → Remove Artwork !)       │
 │ Speaker    Andrew Huberman              ›  │ ← › pushes that page
 │ Album      Season 3                     ›  │
 │ Show       Huberman Lab                 ›  │
 │ Year       2026 · from album               │ ← the album's year as the
 │ Track no.  4                               │   placeholder; type to override
 │ 🌐 Language: English ▾                     │ ← Inherit (speaker) first
 │ Duration   41 min                          │
 │ Size       24.1 MB                         │
 │ File       s3://slmx-archives2/bible-aud…  │ ← tap opens it up, whole path
 │ Also at    files://Podcasts/ep-004.mp3     │   wrapped over as many lines
 │            ( 📁 Show in storage )          │   as it takes
 │ Playlists  ( Listen Later ) ( Bible ) ( ＋ )│ ← ＋ opens Add to Playlist
 │ Topics     ( Sleep ) ( Focus ) ( ＋ )       │ ← the album's, not this one's
 │ ───────────────────────────────────────    │
 │ SUMMARY                          Edit  ✨  │ ← Edit only once expanded
 │ Two sentences about what this episode is…  │   ✨ greyed out until there
 │ • [2:05] Light in the morning.             │   is a transcript
 │ • [12:14] Caffeine has a half-life…        │
 │ ( More )                                   │ ← 3 lines until asked
 └────────────────────────────────────────────┘
 ┌ TERMS ─────────────────────────────────────┐  (only when analysed)
 │ ( melatonin 9 ) ( cortisol 5 ) ( Stanford 2 )│ ← tap → that term's page
 └────────────────────────────────────────────┘
 │ ───────────────────────────────────────    │
 │ ✨ Suggest with AI            ⟳            │
 │ Only 40% of this episode is transcribed…   │ ← blocked reason in place
 └────────────────────────────────────────────┘
 ┌ MY IMPRESSIONS ────────────────────────────┐
 │ What you made of it                        │ ← 2…8 lines, grows
 └────────────────────────────────────────────┘
 ┌ BOOKMARKS AND NOTES ───────────────────────┐
 │ 12:14  "…pipe in personal data"         ✎  │ ← the marks, and what was
 └────────────────────────────────────────────┘   typed against them
 ┌ ABOUT THE SHOW ────────────────────────────┐  (only if a summary exists)
```

A row with no value hides itself rather than printing a dash, so a
thin-metadata episode shows a short card, not a column of blanks.

## Where the file is — one row per copy

The FILE card is gone. It said in five rows (connection, folder, file, format,
size) what one address says: `s3://bucket/folder/ep-004.mp3`, written the way
that cloud's own tooling writes it, extension and all. It sits with Duration and
Size, among the other facts about the recording, and tapping it opens the bucket
browser standing on the file.

**One row per copy.** The same recording in two buckets — or twice in one, under
two names — is one episode with two addresses (`FileFingerprint`,
`Sources/DB/Models/TrackFile.swift`). The first row is the copy it plays from;
the rest read `Also at`. A copy the last sync didn't list says so on the row
rather than leaving it to be discovered by tapping it.

**Tapping the path opens it, it doesn't leave the page.** A bucket, two folders and
an episode name is easily sixty characters, and `s3://slmx-archives2/bible-au…` has
lost the half that identifies it. So the row expands in place and the path wraps
over as many lines as it needs, breaking mid-name — a path is one long word, and
there is no polite place to break it. The bucket browser is then a labelled row
underneath, which says what it does; the whole row silently meaning "leave this
page" was only ever readable because a clipped path left nothing else a tap could
have meant.

The DATES card is gone too: changed-on-storage, last-synced, last-played,
details-edited, stopped-at — five rows answering a question nobody asks while
listening. Every one of them is still in the database for the things that do ask.

## Commit model

```
 leave a field ─▶ save        scrolling away and closing count too
 pick artwork  ─▶ save        already a deliberate, finished act
 playback moves on mid-edit ─▶ the draft stays with the track it was typed
                               for (draftTrackID), never lands on the next
 sync lands mid-edit ─▶ half-typed words win; fields are not refilled
```

## Episode edit sheet

`Player/EpisodeEditView.swift` — the same fields as a modal, reached from a
long-press on any row (`Edit Details`).

```
 Cancel          Edit Episode            Save·   ← disabled while title empty
 ┌────────────────────────────────────────────┐
 │        ▢ artwork (tap to pick)             │
 ├ EPISODE ───────────────────────────────────┤
 │ Title · Speaker · Album · Show · Year ·    │
 │ Track no. · Spoken language ▾              │
 ├ MY IMPRESSIONS ─────────────────────────────┤
 ├ ✨ Suggest with AI                      ⟳  │
 │ Reads this episode's transcript — the whole│
 │ of it, which is why it waits for           │
 │ transcribing to finish. Fills the fields   │
 │ in above; nothing is saved until you tap   │
 │ Save.                                      │
 ├ FILE ──────────────────────────────────────┤
 │ path, read-only  ← the one field that is   │
 │                    what the file actually  │
 │                    is                      │
 └────────────────────────────────────────────┘
```

`Suggest with AI` is disabled until the transcript is **complete**, with the
reason in its place. A partial transcript names the whole episode after its
first ten minutes, and a confident wrong title is worse than a generic tag.

Above Topics sits **Playlists** — chips for every list this episode is on
(Listen Later first, then the hand-made ones), and a `＋` chip that opens the
same "Add to Playlist" sheet the transport used to. Shown even at none: a row
that appears only once it has something in it can't be used to put the first
thing in. Taking an episode *off* a list stays on that list's own page.

## Summary and terms

One ✨, one call, two answers: the summary and the terms come off the same read
of the transcript, since a second call pays for the same tokens to ask a smaller
question. The transcript goes in **with its timestamps**, which is the whole
difference between a summary and a useful one — every `[12:34]` in the text is a
tap that plays from there, in a generated summary and a hand-typed one alike.

```
 brief        two or three sentences: what this is, who it's for
 points       up to eight, in order, each carrying the time it starts
 conclusion   only when the episode lands somewhere; null when it just ends
```

Three lines until More; Edit appears only once it's open — a pencil beside three
clipped lines edits something you can't see. ✨ is a small glyph rather than the
thing your thumb lands on: it writes over what's there, and a summary someone
typed shouldn't be one tap from a model's.

Counts on the term chips are the **app's own**, taken by scanning the transcript
for whole words. A model asked how often it said something guesses, and a
frequency ranking built on guesses ranks nothing.

Named for whose words they are rather than for their subject. "Notes" sat on the
same page as the AI summary, which is also prose about the episode, and as the
BOOKMARKS AND NOTES section, which is prose about one moment in it — three things
called notes. This is the only text on the page that nobody but the listener can
write, so it says so.

## Bookmarks

`Player/Bookmarks.swift`.

```
 row     12:14   "…once you pipe in personal data"        ✎
         Saved moment            ← when no transcript text was captured
   ↑ the row plays from the moment; ✎ opens the note. A saved moment is saved
     to go back to, so going back to it is the whole row.

 editor  card over whatever opened it, keyboard closed until you tap the box
         ┌────────────────────────────────────┐
         │ 12:14  Sleep Toolkit — Part 2   🗑! │ ← trash as far from Save as
         │ "…once you pipe in personal data"  │   the card is wide
         │ ┌────────────────────────────────┐ │
         │ │ Why this moment matters        │ │ grows 1→10 lines
         │ └────────────────────────────────┘ │
         │ ( Cancel )            [[ Save ]]   │
         └────────────────────────────────────┘
```

The spoken line travels with the mark: what was said there is the reason it
was marked, and a re-transcribe must not rewrite it.
