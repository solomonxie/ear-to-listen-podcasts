# Now Playing

`Sources/Screens/Player/RealPlayerView.swift` — a sheet from the mini player,
but built as a page: a back chevron where every page has one, and a 22pt
left-edge strip that drags the whole sheet with the finger.

```
 ‹          Now Playing                       ← tap title = back to top
 ┌─────────────────────────────────────────┐
 │              [ artwork ]                │  220pt, deterministic colour
 └─────────────────────────────────────────┘
              Sleep Toolkit                   title, centred
       …/archives/bible/ep-004.mp3            ← head-truncated path
    Speaker: Huberman   Album: Season 3       ← each pushes that page
 ├───────────●─────────────────────────────┤  tap anywhere to seek
 12:14                               41:02
      ♡     ⏮     ( ⏸ )     ⏭     🔖③        ← favourite | bookmark flank
                                                the transport on purpose
      [ ☰ Up Next (12) ]  [ ＋ Add to Playlist ]
      ⚠ You're offline. Connect to the        ← engine.lastError, orange
        internet to stream this track.
 ─────────── details cards → details.md ────
 ─────────── transcript   → transcript.md ──
```

The whole page is one scroller: artwork and transport scroll away under a
40-minute transcript. No segmented control between details and transcript —
they are read together.

## Once the transport scrolls off

```
                                      ( ↑ Back to top )   centred, thumb reach
 ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  progress, 60% height
 ⏸   12:14 / 41:02                          ⏭   docked bar, appears only
                                                when the big transport is gone
```

Two thresholds, not one (`edge < 0` to show, `edge > 96` to hide): the bar
shortens the scroller, which would otherwise push the transport back into view
and flicker.

## Fast-scroll rail

Right edge, only when the page runs past its own height. A 46pt disc, not a
hairline — a bar down the edge of a page of text is there in principle and
unfindable in practice. The system's own indicator is off: two things down one
edge is what this replaces, not joins.

```
 at rest      dragging
              ───────
   ( ↕ )      ( ↕ )      accent fill, white glyph, 1.1×
              ───────     56pt hit strip either way
```

Never hidden, only dimmed to 40% once the page has been still 3s: a control that
vanishes has to be summoned back before it can be used, and scrolling to find
the thing that scrolls is silly. Position is measured from the scroll view, so
it means the same on an episode with no transcript at all.

## Up Next — sheet, medium/large detents

```
        Up Next
 🔊 Sleep Toolkit            ← speaker icon marks the current track
    ep-004.mp3
    Focus & Flow
    ep-011.mp3
```

## Rules the drawing encodes

- Favourite and bookmark flank the transport: both are things you do *because
  of what you are hearing now*. A mark you go hunting for is made too late.
- The bookmark icon carries its own count badge (`🔖③`), filled once >0.
- Any deliberate 12pt drag turns transcript following off — the reader wins
  over the auto-scroll.
- Scrubber holds the finger's position locally while dragging, so the engine's
  0.5s time publishing cannot yank the thumb back.

```
✗ Now Playing as its own tab, or a card that can only be swiped down
  — it has a back button and an edge swipe like every other page here
```
