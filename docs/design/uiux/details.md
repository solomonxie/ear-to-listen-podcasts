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
 ┌ NOTES ─────────────────────────────────────┐
 │ What this episode is about                 │ ← 2…8 lines, grows
 └────────────────────────────────────────────┘
 ┌ BOOKMARKS ─────────────────────────────────┐  (only when there are any)
 │ 12:14  "…pipe in personal data"         ✎  │
 └────────────────────────────────────────────┘
 ┌ FILE ──────────────────────────────────────┐
 │ Connection   slmx-archives2                │
 │ Folder       bible-audio/2026              │
 │ File         ep-004.mp3                    │
 │ Format       MP3                           │
 │ Size         24.1 MB                       │
 │ Downloaded   24.1 MB   /   Not downloaded  │
 └────────────────────────────────────────────┘
 ┌ DATES ─────────────────────────────────────┐
 │ Changed on storage  Sep 12, 2026 4:13 PM   │
 │ Last synced         Sep 16, 2026 9:02 AM   │
 │ Last played         Never                  │
 │ Details edited      —                      │
 │ Stopped at          12:14                  │
 └────────────────────────────────────────────┘
 ┌ ABOUT THE SHOW ────────────────────────────┐  (only if a summary exists)
```

A row with no value hides itself rather than printing a dash, so a
thin-metadata episode shows a short card, not a column of blanks.

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
 ├ NOTES ─────────────────────────────────────┤
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

## Bookmarks

`Player/Bookmarks.swift`.

```
 row     12:14   "…once you pipe in personal data"        ✎
         Saved moment            ← when no transcript text was captured

 editor  Cancel          Bookmark             Save
         At        12:14
         Episode   Sleep Toolkit — Part 2
         Saved     Sep 16, 2026 4:13 PM
         ┌ NOTE ──────────────────────────────┐
         │ Why this moment matters            │
         ├ TAGS ──────────────────────────────┤
         │ Comma separated                    │
         │ Your own words for finding this    │
         │ again — "quote", "to check", a     │
         │ person's name.                     │
         ├ TRANSCRIPT ────────────────────────┤
         │ What was said here                 │
         │ Copied from the transcript when the│
         │ mark was made. Correcting it here  │
         │ changes the bookmark only.         │
         └────────────────────────────────────┘
         [ Delete Bookmark ]!
```

The spoken line travels with the mark: what was said there is the reason it
was marked, and a re-transcribe must not rewrite it.
