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
  12:14  ✎ edited                          ✎  ← pencil on the right edge
```

One button per recogniser and nothing else. Each transcribes the **whole
episode** in the background, front to back, regardless of what playback is
doing; the text appears all at once when the pass is done. Which recogniser
is the only real choice here — free and on this phone, or more accurate and
charged for — so it is two buttons rather than a switch, a picker and a mode
to understand first.

```
On-device  idle → "On-device"   running → "Stop"
AI         idle → "AI"          running → "Stop"
Follow     off  → "Follow"      on      → "Following"
```

Pressing the running one stops it; the other is disabled while a pass runs —
two passes over the same audio is twice the battery for one transcript.
`Follow` is disabled while already following or with no lines.

**Nothing on disk changes until a pass finishes**, so pressing a recogniser on
an episode that already has a transcript leaves the old one whole and readable
until the new one is ready. A pass abandoned halfway is thrown away rather than
half-applied.

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
           appears here at once when it's finished.
```

## Correcting a line

```
 tap line          → plays from there AND turns Following on
 tap ✎  / long-press → Correct this line ▸
 long-press menu   ▶ Play from here
                   ✎ Correct this line
```

```
 Cancel        Correct line          Save
 At 12:14
 ┌─────────────────────────────────────────┐
 │ Which matters once you pipe in personal │  ← whole line, editable
 │ data.                                   │
 └─────────────────────────────────────────┘
 Saved on this device, and used as a hint for the rest of the
 episode — names and terms you fix once stop coming back wrong.
```

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
- Off for every episode, never remembered: transcribing spends battery or
  money. Anything transcribed before still shows with it off.
