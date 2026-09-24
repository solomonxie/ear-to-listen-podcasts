# Transcript

`Sources/Screens/Player/TranscriptPane.swift` — the bottom half of Now
Playing, lyric-style. Controls flat above the lines, never in a menu.

```
 TRANSCRIPT                              3 edits   ← text button, only when there are edits
 ┌───────────┐ ┌───────────┐ ┌───────────┐
 │     📱    │ │     ✨    │ │     ⌖     │   icon over caption, tint = running
 │ On-device │ │    AI     │ │  Follow   │
 └───────────┘ └───────────┘ └───────────┘
 Transcribing the whole episode · 46%          ← status line, secondary
 ⚠ Stopped at 46% — Speech recognition isn't allowed
 ───────────────────────────────────────────────
  …so the model runs entirely locally.       ← dim
  Which matters once you pipe in personal    ← BRIGHT: the spoken line,
  data.                                        scrolls itself to centre
  12:14  ✎ edited                             ← hold a line for its menu
```

```
 hold a line   ( ▶ Play from here )  ( 🔖 Add bookmark )
               ( ⧉ Copy )            ( ✎ Edit )
               ( ✓ Select )
```

Add bookmark marks where that line starts and keeps the line itself as the
mark's text — the most accurate a mark ever gets, since it's the sentence you
were looking at rather than whatever was playing when your thumb landed. It
doesn't scroll anywhere: the mark is made while you're reading, and being thrown
up to the Notes section would lose the line you marked it for.

One button per recogniser and nothing else. Each transcribes the **whole
episode** in the background, filling in the stretches that have nothing yet,
regardless of what playback is doing; the text appears all at once when the pass
is done. Which recogniser
is the only real choice here — free and on this phone, or more accurate and
charged for — so it is two buttons rather than a switch, a picker and a mode
to understand first.

```
On-device  idle → "On-device"   running → "Transcribing…"  ■ stop square
AI         idle → "AI"          running → "Transcribing…"  ■ stop square
Follow     off  → "Follow"      on      → "Following"
```

The running one says what it's doing, not what pressing it does — the square
already says that, and "Stop" left the page with no word for the thing taking
all this time. Pressing it again stops, at any point; what's already recognised
stays.

**AI asks first, with the number in it.** On-device never asks — there is
nothing to agree to:

```
 ┌──────────────────────────────────────────────┐
 │ Transcribe with AI?                          │
 │ 41 min of audio, about $0.25 charged to your │
 │ own OpenAI key. Only the part with no        │
 │ transcript yet is sent.                      │
 │        [ Transcribe ]        ( Cancel )      │
 └──────────────────────────────────────────────┘
```

The length is what would actually be **sent** — the holes, not the episode — so
a second run after an interrupted one quotes a fraction of the first. Under a
cent reads as "under $0.01" rather than "$0.00", which would look free.

Pressing the running one stops it; the other is disabled while a pass runs —
two passes over the same audio is twice the battery for one transcript.
`[ 💬 Transcript ]` under the transport lands on the line **being spoken**, with
following on, so the page keeps up from there. Landing on the section heading was
only ever right for an episode nobody had started; forty minutes in it put the
reader at the top of forty minutes of text with their place somewhere below it.
The heading is still the answer when there is no line to jump to — at 0 nothing
has been spoken, and an episode played past the end of a part-finished transcript
has nothing at that second either.

`Follow` is disabled while already following or with no lines — it also floats
beside "Back to top" once the transport scrolls off, as a toggle (see
`player.md`).

Correcting a line happens in the line itself — see "Editing a phrase, in place"
below. Nothing is permanently down the right edge: a button per row was a target
for something done once or twice an episode, and it sat under the fast-scroll
handle.

**Every window is kept the moment it lands — and none of it is shown until the
pass is done.** Keeping and showing are separate: the page holds the transcript
as it stood when the pass began, so it never grows a line at a time under the
reader, while what's been recognised is safe on disk the whole time. Leaving the
app, taking a call, or a recogniser dying costs the window in flight and nothing
else — coming back picks up at the first stretch with nothing in it rather than
starting over:

```
 leave at 46%  →  come back  →  Transcribing the whole episode · 46%
                               ↑ resumed by itself, not from zero
```

A stretch nothing was heard in is only written down as silence once the pass
proves the recogniser is working — silence is never looked at again, and a
recogniser that has quietly stopped looks exactly like a quiet episode:

```
 ⚠ Stopped — nothing was recognised in 3 minutes of audio.
   Check the episode's language, or try the other recogniser.
```

Live transcription was removed: text rewrote itself under the reader, the page
flickered, and the same audio was recognised several times over as the playhead
moved. A percentage says as much and costs nothing.

## Status line, all four readings

```
 Transcribing the whole episode · 46%
 From a transcript file beside the episode        ← cost nothing to make
 Whole episode transcribed
 46% transcribed                                  ← an earlier pass, stopped
```

## Empty — says which kind of nothing

```
 ┌─────────────────────────────────────────────┐
 │                 💬                          │
 │        No transcript yet                    │
 │  Nothing transcribed yet. On-device costs   │
 │  battery and no money; AI is more accurate, │
 │  needs a key, and sends the audio to the    │
 │  vendor. Either one does the whole episode  │
 │  in the background.                         │
 └─────────────────────────────────────────────┘
 running   Working through the episode — 46% done. The whole transcript
           The whole transcript appears here at once when it's finished
           — and leaving the app doesn't lose what's already done.
```

## Editing a phrase, in place

```
 tap a line     → plays from there, turns Following on,
                  AND shows what else can be done with it
 ┌───────────────────────────────────────────────┐
 │ Which matters once you pipe in personal data. │
 │ 12:14  ✎ edited          ⟨⧉ Copy⟩ ⟨✎ Edit⟩    │ ← same row, revealed by the tap
 └───────────────────────────────────────────────┘
 tap the same line again → buttons away
 long-press              ▶ Play from here
                         ⧉ Copy
                         ✎ Edit
```

`✎ Edit` turns the row into a field, focused, with the two answers beside it:

```
 ┌─────────────────────────────────────────┐  ✓  ✕
 │ Which matters once you pipe in personal │
 │ data.                                   │
 └─────────────────────────────────────────┘
   ✓ save · ✕ leave it as it was
```

- **The keyboard comes up by itself** — it's the point of tapping Edit — and the
  line is pulled to the top of the page, which is the half of the screen the
  keyboard leaves.
- **Following goes off the moment editing starts.** It would otherwise scroll the
  line being typed in out from under the keyboard within seconds.
- **No page, no sheet.** The lines above and below are the context a correction is
  made against, and both would cover exactly those. It is one line of text; it
  gets one line of UI.
- Saving is `TranscriptStore.applyEdit`: the line is marked edited so the next
  pass can't write over it, the correction is filed for the diff view and the
  vocabulary hints, and the transcript goes back beside the audio at once.

`3 edits` opens the word-level diff, newest first:

```
                My corrections              Done
 At 12:14                      Sep 16, 2026 4:13 PM
 Which matters once you ~~type~~ pipe in personal data.
                          ↑ red strike      ↑ green
 ─────────────────────────────────────────────────────
 (empty) ✎ No corrections yet
```

## Transcribe again… — confirmation

```
 ┌───────────────────────────────────────────┐
 │ Transcribe this episode again?            │
 │ Throws away the stored transcript and     │
 │ starts over. Your corrections are kept —  │
 │ they're used as hints for the new pass.   │
 │  [ Re-transcribe everything ]!  ( Cancel )│
 └───────────────────────────────────────────┘
```

## Language lives with the episode, not here

```
 in details.md, EPISODE card:   🌐 Language: English ▾
```

The spoken language decides how this episode is recognised, so it is asked
for where the episode is described. Inherit (speaker) → album → app default.

## Rules

- Every option is in view and in a fixed place. A menu made each one
  tap-and-hunt, and hid whether anything was running at all.
- What the switch governs is **dimmed, not hidden** — the section must not
  reflow under a thumb.
- Off for every episode, never remembered, and with no global switch in
  Settings to change that: transcribing spends battery or money, and it's
  asked for here or not at all. Anything transcribed before still shows with
  it off.

## Fixing where the recogniser put the line breaks

A recogniser decides where one line ends on silence, and gets it wrong in both
directions: a pause mid-sentence becomes two lines, and a speaker who doesn't
pause becomes one line holding three sentences. Neither is correctable by editing
text — the boundary itself is the mistake.

`✓ Select` off the hold menu turns the list into a picker.

```
 ○  12:14  We were talking about                 tap toggles
 ●  12:19  the default configuration             ← two picked, adjacent
 ○  12:23  which nobody changes

 [ 2 selected ]                    ( Merge ) ( Split ) ( Done )
```

- **A non-empty selection *is* the mode.** No separate flag: a mode with nothing
  picked has no actions, nothing to say, and needs its own way out.
- **The bar replaces the recogniser row** rather than stacking under it. Offering
  to start a fresh pass over lines somebody is halfway through rearranging is
  offering to destroy them.
- **The tick column appears only while picking.** A permanent one would indent
  every line of every transcript for a mode almost nobody is in.
- **Nothing on hold while picking.** Every item in that menu acts on a single
  line, and the press that opens it is also how you reach for another tick.
- **Merge wants two or more, adjacent.** Across a gap it would either throw the
  lines between away or swallow lines nobody picked, so the button goes dim
  instead of choosing one of those for you. The store refuses it too — a store
  that trusts callers to have checked corrupts a transcript the first time one
  doesn't.
- **Split wants exactly one**, and asks two questions about it.

```
 Split line
 First line   │ We were talking about
 Second line  │ the default configuration

 Where the text divides    ──────●────────   snaps to a word
 Where the second starts   ────●──────────   12:19.4
```

Both points are needed and **neither answers for the other**. The text says
where the sentence divides; the time says when the second half starts being
spoken, which is what a tap on that line seeks to. Deriving the time from the
character offset misplaces the seek on any line whose halves aren't read at the
same pace, which is most of them. The time does *follow* the text point until
it's set by hand — right far more often than the middle of the line — and then
stays put, because snapping it back would undo the more careful of the two
decisions.

Both halves stay on screen throughout. They are the only way to tell a good cut
from one that leaves a dangling word, and controls without the result make this a
guess with a confirm button.

The text point snaps to word starts where the language has them and moves one
character at a time where it doesn't. A Chinese or Japanese line has exactly one
word by any space-based reckoning — and is the line that needs splitting most,
since a recogniser with no spaces to go on runs whole sentences together.

Both operations mark what they produce edited, so the next pass can't merge its
own version of the span back over a boundary somebody set by hand, and both
rewrite the sidecar and recount the terms — joining two lines can put a name back
together that was split across them and counted as neither.
