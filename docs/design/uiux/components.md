# Components

## Episode row  `Home/TrackRow.swift`

The one row every list uses.

```
 ┌──┐ Sleep Toolkit — Part 2                 title, 1 line, semibold
 │▢ │ …/bible-audio/2026/ep-004.mp3          path, head-truncated
 └──┘ 41 min   ⚠ Missing                     duration · lost badge
  44                                         long-press → Edit Details
```

Title **and** path, everywhere an episode is listed. Not a fallback for a
missing title: whole folders routinely share one embedded title tag, and then
the path is the only thing telling two episodes apart. Truncated at the head
so the filename — the telling end — survives.

```
 where it is narrower      what it shows
 mini player               filename only  (ep-004.mp3)
 shelf card                filename only, caption2
 Up Next                   filename only
 rows, Now Playing         the whole path
```

## Cards on Home

```
 TrackCard       160 wide   ┌────────────┐  90pt tile
                            └────────────┘  title (1 line)
                            filename
                            ████░░░░ only when part-played

 Album/Show/     120 wide   ▢ 120×120 gradient + glyph
 PlaylistCard               name (1 line)

 SpeakerCard      90 wide   ◯ 90pt photo or 👤 placeholder
                            name (1 line)

 ChipCard                   ( 2026 )  capsule, colour at 20% + same hue text

 BookmarkCard               12:14 · "…pipe in personal data"
                            long-press → Edit Bookmark…
```

Card titles are one line — two-line titles give cards in the same shelf
different heights and the progress bars stop aligning.

## Artwork  `App/ArtworkTile.swift`

```
 with file   the saved image, filled, clipped to the corner radius
 without     deterministic gradient from the row's id + a white glyph
             track ▸ waveform · album/playlist ▸ ▦ · show ▸ 🎙
 radius      6 rows · 10 cards · 14 album header · 16 now playing
```

No blank grey box anywhere: an id always produces the same colour, so an
untagged library still looks sorted rather than broken.

## Section typography  `App/SectionTypography.swift`

```
 sectionTitle          title2 bold      "Remote" · "Settings"
 sectionHeading        caption semibold, secondary, CAPS   "SYNC & BACKUP"
 sectionRow            subheadline      every row's default
 sectionRowSecondary   caption, secondary    second line of a row
 sectionHint           footnote, secondary   the line under a heading
 SectionHeading(ⓘ)     heading + info popover, max 320 wide
```

Rows inherit `.sectionRow()`; headings and hints opt out explicitly —
without it every `Label` falls back to `.body` and dwarfs its own heading.

## Cross-cutting states

| Surface | Loading | Empty | Error / offline |
|---|---|---|---|
| Remote browser | ⟳ in place of the list, footer withheld | This folder is empty. | ⚠ orange line above the list |
| Queue | — | Nothing queued… | per-row error + ↻ retry |
| Now playing | — | 🎙⃠ Nothing playing | ⚠ orange line under the transport |
| Transcript | status line + lines as they land | four different "nothing yet" texts | ⚠ + ( Try again ) |
| Downloads | ⟳ | No downloaded episodes yet… | — |
| Add S3 / AI key | ⟳ on Save | — | inline ⊗ line, never an alert |

- A track missing from the last listing is badged **Missing**, never deleted.
- A stats footer is withheld until its list resolves, so numbers never float
  above an empty list.

## Pickers unfold, they don't float

`Sources/App/UnfoldingPicker.swift`. A form field's options open **in the
field's own row**, pushing the rest of the form down. A menu or sheet covers
exactly the context the choice is made from: the row's label, the fields
already filled, the value being replaced.

```
 Language        English  ›        Language        English  ⌄
 Notes                        →    ┌───────────────────────────┐
 Topics                            │   Inherit (automatic)     │
                                   │ ✓ English                 │
                                   │   中文                     │
                                   └───────────────────────────┘
                                   Notes
                                   Topics     ← pushed down, not covered
```

- The row doesn't move; everything below it does. No backdrop, no transition,
  nothing to dismiss.
- **One open at a time** — every picker in a form shares one `open` binding.
- The chevron turns `›` → `⌄`.
- **No Cancel / Done.** Picking folds it; tapping the row again folds it
  unchanged.

`UnfoldingTextField` is the same bargain for naming something — a `⊕ New
Playlist` row that unfolds into a field, rather than an alert over the list
you're adding to.

**Still a sheet or menu, not this:** a list's filter, a toolbar `⋯`, a
destructive confirm, or a system picker that needs the screen (photos).

Converted: spoken language (album/speaker/episode), AI vendor, AI model, app
language, sync frequency, both "New Playlist" prompts.

## Rows you can actually hit

`DetailLayout.rowHeight` is 44pt — Apple's minimum target. The player's episode
card is a column of fields used one-handed while something plays; `.footnote`
text with no padding gave a ~22pt row, which is a target you aim at.

**A link row is a link, whole.** Speaker and Album on the episode card go
somewhere, so the entire row is the target and the value is in the accent
colour. **No chevron** — the colour already says it goes somewhere, and an
arrow at the far edge is a second thing to look at that points back at what you
already decided to tap.

```
✗  Speaker    华贤                    ›     ← only the › worked, far from the name
✓  Speaker    华贤                          ← whole row, accent value, no arrow
```

Editing those two moved to `EpisodeEditView`: from the player you go to the
speaker, you don't rename them.

## Numbers come off a wheel, not a keypad

`UnfoldingWheel`. A year and a track number are picked from a short, ordered,
known range. A keypad covers half the screen, offers every number including the
wrong ones, and needs a Done to dismiss.

```
 Year            2026  ›        Year            2026  ⌄
 Track no.        —    ›   →    ┌────────────────────────┐
                                │         2027           │
                                │      ▸  2026  ◂        │
                                │         2025           │
                                └────────────────────────┘
                                Track no.        —    ›
```

A continuous control **commits as it moves** — no Done, the row updates under
your thumb. `—` is on the wheel itself, since there's no keyboard to delete
from and "unset" is a real answer for both.

Converted: episode year and track no. (player card and editor), album year.

Left as a keypad: nothing. Left as text: names, notes, bio, background,
profile, topics, playlist names — free text, where a list would be wrong.
