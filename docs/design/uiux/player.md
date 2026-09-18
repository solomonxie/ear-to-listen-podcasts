# Now Playing

`Sources/Screens/Player/RealPlayerView.swift` — a full-screen card over the
mini player, put down by pulling it down. It follows the finger and shrinks as
it goes; the chevron top-left points the same way.

```
 drag the artwork or titles   110pt, or a flick   ← the one that gets used
 pull the whole page past its own top   70pt of overscroll
```

Two ways in because the page is one long scroll: below the header the drag
belongs to the transcript, and overscroll rubber-bands, so a threshold read off
the scroll view alone asks for a stroke longer than the screen.

```
 ⌄          Now Playing                       ← tap title = back to top
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
      [ ☰ Chapters (12) ]  [ ＋ Add to Playlist ]
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
                        ( ↑ Back to top ) ( ⌖ Follow )   centred, thumb reach
 ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  progress, 60% height
 ⏸   12:14 / 41:02                          ⏭   docked bar, appears only
                                                when the big transport is gone
```

Two thresholds, not one (`edge < 0` to show, `edge > 96` to hide): the bar
shortens the scroller, which would otherwise push the transport back into view
and flicker.

Follow floats beside Back to top because that is where the thumb is when you
have just scrolled off the spoken line; the copy above the transcript only
turns it on, this one toggles. One label and one icon either way — colour
alone says whether it's on, so the button doesn't change under the thumb.

## Moving through a book: by chapter, not by scrollbar

There is no fast-scroll handle. Dragging a position along a whole book to find
where you were is a control that asks the reader to aim; nobody knows what 43%
of a book is. Two ways instead, and they are the two anyone reaching for it
actually wanted:

```
 swipe ◀ / ▶ on the artwork      the next / previous chapter, with a tap of
                                 haptic feedback — where a book's pages go
 [ ☰ Chapters (12) ]             the list, to jump straight to one
 ⏮ ⏭ in the transport            the same move, for a thumb already there
```

The header carries both drags, told apart by which way the finger went: **down**
puts the card away, **sideways** changes chapter. Dragging *up* on the artwork
is how you reach the transcript, and that belongs to the scroll view.

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
✗ Now Playing as its own tab
✗ A pencil on every transcript line — correcting is once or twice an episode,
  and a per-line button was a permanent target down the right edge. Hold a line.
```
