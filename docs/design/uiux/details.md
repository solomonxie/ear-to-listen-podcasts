# Episode details & edit

`Sources/Screens/Player/EpisodeDetailsPane.swift` — grouped cards under the
transport, so "who/what" never blurs into "which file". The EPISODE card *is*
the editor: every field is live, shows even when empty, and commits when it
loses focus.

```
 ┌ EPISODE ───────────────────────────────────┐
 │ ▢  Sleep Toolkit — Part 2                  │ ← tap ▢ = photo picker
 │ 64 (long-press ▢ → Remove Artwork !)       │
 │ Speaker    Andrew Huberman              ›  │ ← › pushes that page
 │ Album      Season 3                     ›  │
 │ Show       Huberman Lab                 ›  │
 │ Year       2026                            │
 │ Track no.  4                               │
 │ 🌐 Language: English ▾                     │ ← Inherit (speaker) first
 │ Duration   41 min                          │
 │ ( Sleep ) ( Focus )                        │ ← topic chips, if any
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
