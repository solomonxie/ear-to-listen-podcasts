# CarPlay — implementation plan

Design: `DESIGN.md`. Screens: `UIUX_DESIGN.md`. New code goes in `Sources/CarPlay/`
(run `xcodegen generate` after adding files).

## Phase 0: Entitlement
Apple has to approve this first, and it has a lead time. Everything else can be
built and unit-tested while waiting, but nothing can be shown in a car until it lands.

- [ ] T0.1 Request CarPlay audio entitlement — developer.apple.com/contact/carplay, category Audio — you have to do this — depends: none

## Phase 1: Foundations
The scene, the engine hooks and the data layer are what every template stands
on. The three tasks touch separate files, so they can run in parallel.

- [x] T1.1 CarPlay scene + entitlement — add `UIApplicationSceneManifest` with only a `CPTemplateApplicationSceneSessionRoleApplication` role (the phone's `WindowGroup` stays as it is); `com.apple.developer.carplay-audio` in `EarToListen-CarPlay.entitlements`, used only by `make ios CARPLAY=1` until Apple grants it; a `CarPlaySceneDelegate` that sets an empty tab bar on connect and tears down on disconnect — see `project.yml`, `Sources/App/` — depends: none
- [x] T1.2 Engine hooks — `skipBackward/ForwardCommand` (10s) replace prev/next; a `play(track:queue:startingAt:)` that doesn't set `isPresentingPlayer` (have `open` call it); publish an offline failure the car can show as an alert, not just `lastError` text — see `Sources/Playback/PlaybackEngine.swift` — depends: none
- [x] T1.3 `CarLibrary` data source — one off-main query per list (continue, later, favorites, downloaded, playlists, collections, speakers, bookmarks, episodes-of-X) returning plain row structs with title, detail, progress, isCloud and listened; a window of `maximumItemCount` around the next unplayed episode; a small artwork-thumbnail cache filled only for rows actually shown; unit tests for the windowing and detail strings — see `Sources/CarPlay/`, `Tests/` — depends: none

## Phase 2: Templates
One file per tab, each turning `CarLibrary` rows into `CPListItem`s. They need
all three foundations, and they don't share files with each other.

- [x] T2.1 Listen Now tab — Continue Listening + Listen Later sections, `isPlaying`, `playbackProgress`, `.cloud` — see `UIUX_DESIGN.md → Listen Now` — depends: T1.1, T1.2, T1.3
- [x] T2.2 Library tab + Episodes list — five rows → pushed episode list, capped footer row — see `UIUX_DESIGN.md → Library` — depends: T1.1, T1.2, T1.3
- [x] T2.3 Bookmarks tab — newest first; tap plays from the mark — see `UIUX_DESIGN.md → Bookmarks` — depends: T1.1, T1.2, T1.3
- [x] T2.4 Now Playing — bookmark `CPNowPlayingImageButton` via `MomentMark.add` with 1.5s `isSelected`; Up Next → queue list; album-artist button → Speaker's episodes — see `UIUX_DESIGN.md → Now Playing` — depends: T1.1, T1.2, T1.3

## Phase 3: Wiring and polish
Things that cut across the tabs, so they come after all of them exist.

- [x] T3.1 Live refresh — rebuild the visible list's items in place on `libraryDidChange` / `bookmarksDidChange` / track change, debounced 400ms — see `Sources/CarPlay/CarPlayController.swift` — depends: T2.1, T2.2, T2.3, T2.4
- [x] T3.2 States — empty-view strings, offline `CPAlertTemplate` — see `UIUX_DESIGN.md → States` — depends: T2.1, T2.2, T2.3
- [x] T3.3 Localizable strings for `carplay.*` keys, in every language the app ships — see `Resources/` — depends: T3.2
- [ ] T3.4 Verify — on the iPhone via the CarPlay Simulator Mac app (Xcode Additional Tools) or a real car: cold start with the phone locked, offline cloud episode, mark from the car shows up in the phone's Notes; Release `.app` size unchanged — depends: T0.1, T3.1, T3.2
