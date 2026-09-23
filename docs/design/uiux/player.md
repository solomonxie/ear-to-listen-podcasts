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
      ♡   ⏪10   ( ⏸ )   ⏩10   🔖③           ← favourite | bookmark flank
                                                the transport; ③ = marks on
                                                this episode, and the receipt
                                                for the press
      [ ☰ Up Next ] [ 🔖 Bookmarks ] [ 💬 Transcript ]
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
 ( ↑ Back to top ) ( ⌖ Follow )                     centred, thumb reach
 ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  progress, 60% height
 ▦ Sleep Toolkit · Huberman      🔖③  ⏪10   ⏸   docked bar, appears only
   12:14 / 41:02                                 when the big transport is gone
```

Two thresholds, not one (`edge < 0` to show, `edge > 96` to hide): the bar
shortens the scroller, which would otherwise push the transport back into view
and flicker.

Both floating pills only **move the page** — making a mark is the transport's
bookmark, the docked bar's, and the hold-a-line menu. A button that changes
something, sitting among ones that don't, is the one pressed by accident.

The mark you want to make while listening lives on the docked bar instead:
🔖 left of ⏪10, smaller again than the rewind, marking without jumping — same
as the transport's, since this bar is standing in for it. It's the only control
there that doesn't change what you hear, so it sits outside both of those. Over
Home the bar has no 🔖: there the bar is the way *in*, and a mark made from
there is one made without hearing what's being marked.

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
 [ ☰ Up Next ]                   the list, to jump straight to one
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

- Favourite and bookmark flank the transport: both are things you do *because of
  what you are hearing now*, and both are one tap with nothing to read.
- ⏪10 / ⏩10, not ⏮ / ⏭: spoken audio is missed a sentence at a time, and "what
  did they just say" is what anyone reaches for mid-episode. Moving to another
  episode is a decision made from Up Next, a tap below.
- 🔖 in the transport and on the docked bar **marks and stays put** — being
  thrown down the page while listening is the interruption the mark was supposed
  to avoid. The [ 🔖 Bookmarks ] pill is the other half: it goes to the marks
  without making one. Two wants, two buttons.
- Every marking button carries the count. A button that goes nowhere and asks
  nothing otherwise looks like it did nothing, and the number going up says both
  "that worked" and "this is your fourth". Same second twice is still one mark —
  the store dedupes — so the count can only be honest.
- Adding to a playlist left this row for the Episode card's Playlists field: it's
  a decision about the episode, not about this second of it.
- Any deliberate 12pt drag turns transcript following off — the reader wins
  over the auto-scroll.
- The docked bar carries 🔖, ⏪10 and play/pause, in that order: pause keeps the
  far-right seat it's reached for without looking, the rewind is drawn a size
  smaller so the two don't read as equals, and the bookmark smaller again — it's
  the one that doesn't change what you're hearing. Same three wherever the bar
  stands: over Home, on a page pushed off the player, and docked on the player.
- Scrubber holds the finger's position locally while dragging, so the engine's
  0.5s time publishing cannot yank the thumb back.

```
✗ Now Playing as its own tab
✗ A pencil on every transcript line — correcting is once or twice an episode,
  and a per-line button was a permanent target down the right edge. Hold a line.
```
