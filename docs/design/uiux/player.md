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
 ( ⌖ Follow ) ( ↑ Back to top ) ( 🔖③ )             tap marks · hold → marks
 ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂  progress, 60% height
 ▦ Sleep Toolkit · Huberman      🔖③  ⏪10   ⏸   docked bar, appears only
   12:14 / 41:02                                 when the big transport is gone
```

Two thresholds, not one (`edge < 0` to show, `edge > 96` to hide): the bar
shortens the scroller, which would otherwise push the transport back into view
and flicker.

**Follow leads.** It is the one pressed over and over, mid-read, by a thumb that
has just scrolled off the spoken line; the other two are occasional. Left is
where that thumb lands. The copy above the transcript only turns following on —
this one toggles, because stopping is as likely to be the ask as starting. One
label and one icon either way: colour alone says whether it's on, so the button
doesn't change shape under the thumb that just pressed it.

**None of the three takes you anywhere you didn't ask for.** Back to top moves
the page because that is the whole request, and stops the page moving itself
while it's at it — following and reading the top of the page are contradictory
things to want.

**🔖 is both halves of the subject, split by how long you hold it.**

*Tap* marks and stays put. It does **not** jump to the marks: the reason to mark
from here is that the line worth marking is on screen, and going to the mark
would leave it. *Hold* goes to the marks and makes none.

One control, because they are two halves of one subject and the row has three
places in it.

**The `[ 🔖 Bookmarks ]` pill stays on the row under the transport.** It is not a
duplicate of this hold: that row is only reachable while the transport is on
screen, and this row only exists once the transport has scrolled off. The two
never appear together, so whichever is in front of you has a way to the marks.
The pill carries no haptic — that belongs to the hold, where it is what tells a
jump from a mark left by mistake.

Tap is the far commoner action and gets the shorter gesture. A hold is invisible
to VoiceOver, so the jump is also an accessibility action on the same element.

Gestures, not a `Button` with a `contextMenu`: a menu turns "go to the marks"
into a hold and then a second tap on a one-item list. The repo's rule about
those two fighting is about `onTapGesture` + `contextMenu`, which this isn't.

The haptic on the hold is load-bearing. A tap and a hold on one control have to
feel different as the thumb lifts, or a hold that was meant to jump and instead
left a mark is indistinguishable from one that worked.

Glyph only, at the right end of a row whose other two carry words — the bookmark
is the one shape that needs none. The count on its shoulder is the receipt for a
tap, the same one the transport's bookmark gives: nothing moves, so the number
going up is all there is to say it worked, and it is also worth knowing before
marking the same minute twice.

The docked bar keeps its own 🔖 left of ⏪10, smaller again than the rewind,
marking without jumping, since the bar is standing in for the transport. Over
Home the bar has no 🔖: there the bar is the way *in*, and a mark made from there
is one made without hearing what's being marked.

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
- 🔖 in the transport, on the docked bar and tapped in the floating row **marks
  and stays put** — being thrown down the page while listening is the
  interruption the mark was supposed to avoid. Going *to* the marks is the
  [ 🔖 Bookmarks ] pill while the transport is up, and the same floating button
  held once it isn't. Two wants, never confused for each other.
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
