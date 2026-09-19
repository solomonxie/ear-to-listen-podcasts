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
 Albums      ▢ 120×120 tiles, name under
 Speakers    ◯ 90pt avatars, name under
 Playlists                               ⊕   ← trailing button: new playlist
 ┌──────┐ ┌──────┐ ┌──────┐
 │  ♥   │ │  ⤓   │ │  ▦   │    ← the two fixed ones first, always, even at 0
 └──────┘ └──────┘ └──────┘
 Favorites Downloaded Night li…
 12        128        9         ← count under the name
 Bookmarks                  14 in 5 episodes
 ┌─────────────────────────────────────────┐
 │ 第 3 集 — 人物志                        │  ← episode, once, not per mark
 │ ① 12:14  "…pipe in personal data"    ✎  │
 │ ② 27:40  Saved moment                ✎  │  ← numbered by time within it
 │ ③ 41:02  a note                      ✎  │
 │ 另一集                                  │
 │ ① 05:11  …                           ✎  │
 └─────────────────────────────────────────┘
 Saved Shows
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
history.

**Favorites and Downloaded are fixed playlists, not shelves** — pinned first
in the Playlists row, always present, never deletable. They're computed
(`FixedPlaylist`): favourites from the flag on the track, downloads from what
`AudioCache` actually holds, so there's no row to delete and nothing to keep in
sync. Both show at zero on purpose: a listener who has favourited nothing still
needs telling where favourites will appear, and a shelf that only materialises
once you've found the feature teaches nobody.

**Bookmarks sit below Playlists**, because they're marks made *inside* episodes
rather than a collection of episodes. They're grouped by episode and numbered by
time within it, so "the second mark in that one" is something you can say and
then find. The old version was a horizontal row of one box per mark, each
repeating its episode title, with marks from the same episode scattered along
the row and no count anywhere.

Everything else still hides itself when empty.

## States

```
empty    search bar → Remote → Settings, with no shelves between them
         ← every shelf hides itself while it has nothing in it, so a fresh
           install reads as the normal page minus its content rather than a
           placeholder card. A fresh install's whole point is to go connect a
           source, and Remote is then the first thing under the search bar.
           The sample library stays on offer in Settings.

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
