# Home

`Sources/Screens/Home/HomeView.swift` — the whole app is this one scrolling
page. Reached at launch; nothing pushes back to it but Back.

```
 Good listening                              ← large title
 🔍 Search your podcasts                     ← always shown, bar drawer
 ───────────────────────────────────────────
 Continue Listening
 ┌────────────┐ ┌────────────┐ ┌───────────
 │ [artwork]  │ │ [artwork]  │ │ [artwork]     160×90 tile
 └────────────┘ └────────────┘ └───────────
 Sleep Toolkit   Focus & Flow    Deep Work
 Season 3 · An…  Season 3 · An…  Deep Work…   ← album · speaker
 ████████░░░░    ██░░░░░░░░░░                 ← only if part-played
 Favorites            (hidden when none)
 Bookmarks            (hidden when none)
 Albums      ▢ 120×120 tiles, name under
 Speakers    ◯ 90pt avatars, name under
 Playlists                               ⊕   ← trailing button: new playlist
 Saved Shows
 Downloaded                            More   ← ( More ) → Downloads sheet
 Browse by Year   ( 2026 ) ( 2025 ) ( 2024 )  ← capsule chips
 Topics           ( Sleep ) ( Focus ) ( AI )
 ─────────────────────────────────────────── ← Divider
 Remote        → remote.md
 ─────────────────────────────────────────── ← Divider
 Settings      → settings.md
 ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
 ▶ mini player, docked over everything
```

Shelves are data, never recommendation: Continue Listening is playback
history, Downloaded is what `AudioCache` holds. Favorites and Bookmarks sit
near the top — hand-made marks outrank derived shelves — and vanish entirely
when empty.

## States

```
empty    ┌───────────────────────────────────────┐
         │        ⌧ (square.stack.3d.up.slash)   │
         │   Nothing in your library yet         │
         │   Connect an S3 bucket, or import     │
         │   episodes from Files below, and they │
         │   appear here as they sync.           │
         │      [ Load sample library ]          │
         └───────────────────────────────────────┘
         ← the shelves are replaced by this card, but Remote and Settings
           still follow below it: a fresh install's whole point is to go
           connect a source, so the way to do that stays on screen

typing   search replaces the shelves in place — no push, no overlay

no hits  ⌕ No Results for "huberman"
```

## Search results

```
 🔍 sleep                                    ← query
 Shows
 ▢ 🎙 Sleep Toolkit
 ────────────────────────────────── (inset 68pt)
 Speakers    ▢ 👤 Andrew Huberman
 Albums      ▢ ▦ Season 3
 Playlists   ▢ ▦ Night listening
 Topics      ▢ # Sleep
 Episodes    → full TrackRow, tapping plays with the hits as the queue
```

Six sections, fixed order: Shows · Speakers · Albums · Playlists · Topics ·
Episodes. An empty section is not drawn. Episodes match title **or file
path** — a folder of files often shares one embedded title tag.

## Episode row — everywhere one appears  `Home/TrackRow.swift`

```
 ▢  Sleep Toolkit — Part 2                    ← 44pt thumbnail: the episode's
 44 Season 3 · Andrew Huberman                  own artwork, else its album's
    41 min                                      (and the album's colour)
 ▢  Untitled 004
 44 …/bible-audio/2026/ep-004.mp3             ← the path only when there is
    18 min  ⚠ Missing                           no album and no speaker
```

Which collection, and whose voice. A folder of files often shares one embedded
title tag, so the second line has to tell two rows apart — and the album and
speaker do that while being worth reading, which a file path never was.

## Mini player

```
 ▁▂▃ progress hairline, 1.5pt, accent ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁
 ▢  Sleep Toolkit                                       ▶
 36 Andrew Huberman · ep-004.mp3                        ⏸
    ← filename only; the bar is too narrow for a path
```

Tap anywhere but the play button → Now Playing (sheet). Hidden entirely when
nothing is loaded.
