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
