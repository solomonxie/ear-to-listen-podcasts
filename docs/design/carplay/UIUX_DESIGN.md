# CarPlay — UI/UX

Why and scope: `DESIGN.md`. Every surface below is a stock CarPlay template.
Apple draws them; we only fill them in. Glyphs follow `../uiux/README.md`.
`[CP…]` = template class.

## Screen map

```
 car connects
   │
   ▼
 [CPTabBarTemplate]
   ├─ Listen Now ──tap episode──────────────┐
   ├─ Library ──▶ Playlists  ──▶ Episodes ──┤
   │          ──▶ Collections ─▶ Episodes ──┤
   │          ──▶ Speakers  ──▶ Episodes ───┤
   │          ──▶ Favorites / Downloaded ───┤
   └─ Bookmarks ──tap mark──────────────────┤
                                            ▼
                               [CPNowPlayingTemplate.shared]
                                 ├─ Up Next ─▶ queue list
                                 └─ speaker name ─▶ that Speaker's Episodes
```

Max depth: tab → list → list → Now Playing = 4 (CarPlay allows 5).

## Tab bar

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│                  (selected tab's list)                   │
│                                                          │
├──────────────────────────────────────────────────────────┤
│   ▶ LISTEN NOW       Library        Bookmarks            │
└──────────────────────────────────────────────────────────┘
```
Three tabs, not four: search and settings can't be used while driving.
SF Symbols: `play.circle`, `square.stack`, `bookmark`.

## Listen Now

```
┌──────────────────────────────────────────────────────────┐
│ Listen Now                                               │
│ CONTINUE LISTENING                                       │
│ ┌──┐ Grace in the Wilderness, Part 3              ▶≈   │ ← playing now
│ └──┘ Tim Keller · 23 min left                            │
│      ▓▓▓▓▓▓▓▓▓░░░░░░                                     │ ← playbackProgress
│ ┌──┐ Why the Psalms Still Matter for Anyone Who…  ☁    │ ← not downloaded
│ └──┘ John Piper · 41 min left                            │
│      ▓▓░░░░░░░░░░░░░                                     │
│ LISTEN LATER                                             │
│ ┌──┐ The Prodigal God                              ☁    │
│ └──┘ Tim Keller · 52 min                                 │
└──────────────────────────────────────────────────────────┘
```
- Continue Listening: same rows as Home's shelf, unfinished only, newest first.
- Tap → plays with the episode's collection as the queue → Now Playing.
- `▶≈` = `isPlaying`; `☁` = `accessoryType = .cloud` (needs a network).

## Library

```
┌──────────────────────────────────────────────────────────┐
│ Library                                                  │
│ ♡  Favorites                                           › │
│ ↓  Downloaded                                          › │
│ ≡  Playlists                                           › │
│ ▦  Collections                                         › │
│ 👤 Speakers                                            › │
└──────────────────────────────────────────────────────────┘
```
Listen Later lives on Listen Now and Listened is left out (nobody re-plays
from the car), so this shows the other two fixed playlists plus the three
groupings.

### Episodes list (pushed from any of the above)

```
┌──────────────────────────────────────────────────────────┐
│ ‹ Romans                                                 │
│ ┌──┐ 13. Love Fulfills the Law                     ✓    │ ← listened
│ └──┘ 38 min                                              │
│ ┌──┐ 14. The Weak and the Strong                   ▶≈   │
│ └──┘ 23 min left                                         │
│      ▓▓▓▓▓▓▓▓▓░░░░░░                                     │
│ ┌──┐ 15. Welcome One Another                       ☁    │
│ └──┘ 44 min                                              │
│ …                                                        │
│      (header) Showing 9–108 of 412                      │ ← only when capped
└──────────────────────────────────────────────────────────┘
```
- Collections in episode order; playlists in playlist order; Speakers,
  Favorites, Downloaded newest first.
- **Capped at `CPListTemplate.maximumItemCount`**. Long collections open on a
  window around the next unplayed episode, not on episode 1.
- No counts on these rows: a bare number under a label reads as noise, and
  plurals aren't worth localizing for it.
- `✓` listened: written into the detail line ("Played · 38 min"), since list
  items have no check accessory.

## Bookmarks

```
┌──────────────────────────────────────────────────────────┐
│ Bookmarks                                                │
│ ┌──┐ 12:03 · Grace in the Wilderness, Part 3             │
│ └──┘ "the wilderness is where he meets us, not wh…"      │ ← note, else spoken line
│ ┌──┐ 41:20 · The Prodigal God                            │
│ └──┘ Use for small group                                 │
└──────────────────────────────────────────────────────────┘
```
Newest first, same as Home. Tap → plays from that second → Now Playing.

## Now Playing

```
┌──────────────────────────────────────────────────────────┐
│ ‹                                            Up Next     │
│   ┌────────┐  Grace in the Wilderness, Part 3            │
│   │  art   │  Tim Keller ›                               │ ← album-artist button
│   └────────┘  Romans                                     │
│   ├──────────●─────────────────┤ 18:42   -23:10          │
│      ⟲10        ❚❚        10⟳        [🔖]               │
└──────────────────────────────────────────────────────────┘
```
- ⟲10 / 10⟳ come from `skipBackward/ForwardCommand` (10s). They replace ⏮ ⏭.
- `[🔖]` = `CPNowPlayingImageButton`. Tap marks the current second.

Bookmark tap, before → after (1.5 s, then back):
```
  [ bookmark ]        tap ↓        [ bookmark.fill ]  isSelected = true
```
No count badge and no toast: the template has neither. The filled glyph is the
receipt. Marking the same second twice is a no-op (`MomentMark`'s dedupe).

## States

```
first run   Listen Now   "No episodes yet"
                         "Add a source on your iPhone."     ← emptyViewTitle/Subtitle
empty list  Bookmarks    "No bookmarks yet"
                         "Tap 🔖 while playing to mark a moment."
loading     lists come from the DB straight away; artwork fills in afterwards
offline     ┌──────────────────────────────────────┐        ← CPAlertTemplate
            │ This episode isn't downloaded.       │
            │ Connect to the internet to play it.  │
            │                [ OK ]                │
            └──────────────────────────────────────┘
nothing     Now Playing opened with no track: never; the tab bar is the root
  playing
library     lists rebuild on `libraryDidChange` / `bookmarksDidChange`,
  changed   debounced 400 ms, in place
```

## Copy

| Key | String |
|---|---|
| `carplay.tab.listenNow` | Listen Now |
| `carplay.tab.library` | Library |
| `carplay.tab.bookmarks` | Bookmarks |
| `carplay.section.continue` | Continue Listening |
| `carplay.section.later` | Listen Later |
| `carplay.detail.left` | %@ · %@ left |
| `carplay.detail.played` | Played · %@ |
| `carplay.capped` | Showing %d–%d of %d |
| `carplay.empty.title` | No episodes yet |
| `carplay.empty.subtitle` | Add a source on your iPhone. |
| `carplay.bookmarks.empty.title` | No bookmarks yet |
| `carplay.bookmarks.empty.subtitle` | Tap the bookmark while playing to mark a moment. |
| `carplay.offline` | This episode isn't downloaded. Connect to the internet to play it. |

## Deviations
None from the `uiux` skill, which has no CarPlay rules. Apple's CarPlay HIG and
the template limits are the governing reference.
