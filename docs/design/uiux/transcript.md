# Transcript

`Sources/Screens/Player/TranscriptPane.swift` — the bottom half of Now
Playing, lyric-style. Controls flat above the lines, never in a menu.

```
 TRANSCRIPT              3 edits  Transcribe again…   ← both are text buttons
 ┌────────┐ ┌────────────┐ ┌───────────┐
 │   💬   │ │     ⚡     │ │     ⌖     │   icon over caption, tint = ON
 │Subtitles│ │Whole episode│ │  Follow  │
 └────────┘ └────────────┘ └───────────┘
 [ ON-DEVICE | OpenAI Whisper ]      ← dimmed, not hidden, while off
 Listening to 12:00–13:00… · 46% done          ← status line, secondary
 ⚠ Speech recognition isn't allowed   (Try again)   ← error + inline retry
 ───────────────────────────────────────────────
  …so the model runs entirely locally.       ← dim
  Which matters once you pipe in personal    ← BRIGHT: the spoken line,
  data.                                        scrolls itself to centre
  12:14  ✎ edited                          ✎  ← pencil on the right edge
  hearing…                                     ← volatile tail, one block,
                                                 no timestamp, not tappable
```

Each control's title *is* its state:

```
Subtitles      off → "Subtitles"      on → "Subtitles on"
Whole episode  idle → "Whole episode" / "Resume all" (some coverage)
               running → "Pause"
Follow         off → "Follow"         on → "Following"
```

`Subtitles` disabled with no track · `Whole episode` also disabled once
complete · `Follow` disabled while already following or with no lines.

## Status line, all five readings

```
 Paused with the episode · 46% transcribed
 Listening to 12:00–13:00… · 46% done
 From a transcript file beside the episode        ← cost nothing to make
 Whole episode transcribed
 46% transcribed
```

## Empty — says which kind of nothing

```
 ┌─────────────────────────────────────────────┐
 │                 💬                          │
 │        No transcript yet                    │
 │  Off for this episode — tap Subtitles above │  ← switch off
 │  to start one. Anything transcribed before, │
 │  or a transcript file sitting beside the    │
 │  episode, still shows here either way.      │
 └─────────────────────────────────────────────┘
 on, no window   Listening from where you are — lines appear as they're
                 recognised.
 window running  Working through 12:00–13:00 — … Nothing yet means no
                 speech has been made out so far.
 waiting         Waiting for playback — transcribing follows the episode.
```

A window of music or silence recognises to nothing, so "working" and "nothing
to show" are both true at once — the pane says which stretch it is on rather
than looking broken.

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
