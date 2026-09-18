# Settings

`Sources/Screens/Settings/SettingsSectionView.swift` — the last section of
Home, not a tab. Five groups, each with a short hint under its heading (`ⓘ`
opens the long one), never a paragraph at the bottom.

```
 Settings
 SYNC & BACKUP                                          ⓘ
 iCloud Drive                                           ─●
 Files / iCloud Drive / Ear to Listen · Last: Sep 18, 2026 9:02 AM
 ⬆ Export Library Data
 ⬇ Import Library Data
 <backup status message>
 ↩ Undo restore — put back Sep 18, 2026 2:02 PM   ← only after a restore,
                                                    only while the copy is here

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

## Restoring — asked at the point of action

The picker comes first; the question comes after, with the file already chosen,
and says what will happen rather than "are you sure". The answer depends on
knowing the old library is kept.

```
 ┌────────────────────────────────────────────────┐
 │ Restore from this file?                        │
 │ It becomes your library. The one here now is   │
 │ kept on this phone for a week — you can put    │
 │ it back.                                       │
 │                                                │
 │          [ Restore ]        ( Cancel )         │
 └────────────────────────────────────────────────┘
```

After it lands, the status line says what came back and what's waiting, and the
undo row appears above it for as long as the replaced library is still on the
phone (seven days):

```
 Restored 3 playlists, 41 items waiting for the next sync.
 ↩ Undo restore — put back Sep 18, 2026 2:02 PM
```

The copies on this phone are never listed as a **destination** — they share the
app's sandbox, so deleting the app takes them and the library together. They
show up in two places only: this one button, and the Files app.

## Where the copies live — what ⓘ says

```
 one archive a day (20260918-ear-to-listen.zip), same bytes everywhere
 ├─ this phone   7 days, in Files — for undoing a mistake, not a lost phone
 ├─ iCloud       latest 10, older ones deleted
 └─ the bucket   every one of them, never deleted
 an extra copy before anything big: ear-to-listen-before-import-20260918-140233.zip
 never: your episode files, and never your keys — including in backups
```

## iCloud row — the four unusable states

The explanation **replaces** the location line; only the fixable one carries
directions, spelled out in full.

```
 iCloud Drive                                          ─●
 Files / iCloud Drive / Ear to Listen · Last: Sep 18

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
