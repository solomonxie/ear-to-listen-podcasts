# Settings

`Sources/Screens/Settings/SettingsSectionView.swift` — the last section of
Home, not a tab. Five groups, each with a short hint under its heading (`ⓘ`
opens the long one), never a paragraph at the bottom.

```
 Settings
 SYNC & BACKUP                                          ⓘ
 iCloud Drive                                           ─●
 Files / iCloud Drive / BYO Podcasts · Last: Sep 16, 2026 9:02 AM
 ⬆ Export Library Data
 ⬇ Import Library Data
 <backup status message>

 AI KEYS                                    ⓘ   Sequential ▾
 Better titles during sync, and transcription on playback.
 OpenAI                                    ⌃ ⌄ ⋯        ↑ order = fallback;
 12 requests sent                          ›              disabled under 2 keys
 ⊕ Add AI Key

 TRANSCRIPTS                                            ⓘ
 Transcribe every episode as you listen                 ○─
 Only the episodes you ask for.        ← flips to "On for every episode."

 LANGUAGE                                               ⓘ
 Same as device ▾        ← each option written in its own language

 ADD EPISODES                                           ⓘ
 Import podcasts from Files        ⟳ Importing…
 Read where they sit, never copied.
 Files                                                  ─●   ← existing local
 Found 42 files.                                               sources only
 [ Load sample library ]  ( Remove )!    ← Reset / Remove once loaded
 A few sample shows and clips to look around with.
 ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ 72pt clear of the docked mini player ▁▁▁▁
```

Settings holds only what has nowhere better to live:

```
 downloads      → the Downloaded shelf's own ( More )
 backup to a bucket → that connection's row in Remote  (remote.md)
 sync frequency → the source's row                      (remote.md)
 per-episode transcribing → the episode's own page      (transcript.md)
```

## iCloud row — the four unusable states

The explanation **replaces** the location line; only the fixable one carries
directions, spelled out in full.

```
 iCloud Drive                                          ─●
 Files / iCloud Drive / BYO Podcasts · Last: Sep 16

 iCloud Drive                                       ·  ○─
 iCloud Drive is off on this device.
 Settings → your name → iCloud → iCloud Drive → turn on   ← accent, here only

 iCloud Drive                                       ·  ○─
 This build of the app isn't signed for iCloud.

 iCloud Drive                                       ·  ○─
 Setting up your iCloud folder — try again shortly.

 iCloud Drive                                          ─●
 Last backup to iCloud failed: <error>
```

## Add AI key — sheet, medium detent

```
 Cancel          Add AI Key             Save·   · while empty or testing
 Vendor                              OpenAI ▾
 sk-…                                ••••••
 Don't have a OpenAI key yet?  Get one →
 ⟳ Testing the key…      ← Save itself sends one real, cheap request
 ⊗ Could not connect: <message>
 ─────────────────────────────────────────────
 Stored only in this device's Keychain — we never see it or send it
 anywhere ourselves, it's used solely for direct requests from your
 device to OpenAI.
```

## AI key detail  `Settings/AiKeyDetailView.swift`

```
 ‹ Back            OpenAI
 Requests                   12
 Tokens (last 100)      84,120
 Estimated cost          $0.42     ← list price × tokens; says "estimated"
 ─────────────────────────────────────────────
 Sep 16, 2026 9:02   gpt-4o-mini    1,204 → 88    $0.004   ›
   ▾ prompt and reply, behind the tap
 Sep 16, 2026 8:41   gpt-4o-mini    failed: 429 rate limit          ← kept
```

A request count answers none of the questions people have about a key — what
is this spending money on, why did the bill jump, is this key failing?

## Downloaded  `Settings/DownloadsView.swift` (sheet, from Home's ( More ))

```
            Downloaded
 Sleep Toolkit — Part 2              24.1 MB
 …/bible-audio/2026/ep-004.mp3
 ◀ swipe to delete — drops the local copy only; the episode stays synced
   and re-downloads next play
 loading  ⟳
 empty    No downloaded episodes yet. Anything you play is saved here
          automatically.
```

## Confirmations

```
 ┌───────────────────────────────────────────┐
 │ Reset Sample Library?                     │
 │ This puts back the sample shows, speakers,│
 │ and playlists.                            │
 │            ( Cancel )     [ Reset ]!      │
 └───────────────────────────────────────────┘
 ┌───────────────────────────────────────────┐
 │ Remove Sample Library?                    │
 │ Clears the sample shows, speakers, albums │
 │ and playlists. Your own synced episodes   │
 │ and sources stay. You can load the samples│
 │ again later.                              │
 │            ( Cancel )     [ Remove ]!     │
 └───────────────────────────────────────────┘
```
