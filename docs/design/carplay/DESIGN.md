# CarPlay

## Problem
The car is where a lot of podcast listening happens. Today the app only shows up
there as a generic Now Playing card. You can't pick an episode, resume one, or mark
a moment without picking up the phone.

## Goals
- From the car screen: resume, choose an episode, mark a moment, skip ±10s.
- Same engine, queue and resume position as the phone. CarPlay is a second
  remote, not a second player.
- No size cost: `CarPlay.framework` is part of the system and adds no dependency.
- Tolerates being started cold in the car with the phone locked in a pocket.

## Non-goals
- Search, typing, editing notes, transcripts, AI, sources, settings. Apple bans
  text input for audio apps, and none of it is safe while driving.
- Siri / voice ("play the latest sermon"): `INPlayMediaIntent` is a separate
  piece of work. Backlogged.
- Playback speed: the app doesn't have it on the phone either.
- Downloading for the drive. Uses whatever is already cached or downloaded.

## Options considered
- **Do nothing (Now Playing card only)**: free, but you can't browse and can't
  bookmark. That doesn't meet the goal.
- **`MPPlayableContentManager`**: deprecated since iOS 14 and gives no control
  over the Now Playing screen.
- **CarPlay audio templates (`CPTemplateApplicationScene`)**: the supported
  route. Tab bar + lists + the shared Now Playing template. **Chosen.**

## Decision
Templates. They are the only supported path, and every control the goal needs
fits the template limits: ≤4 tabs, a capped list length, and one custom button
on Now Playing for the bookmark.

Side effects accepted:
- **Skip ±10s replaces previous/next track** in `MPRemoteCommandCenter`. That
  command center is shared, so the lock screen and AirPods change too. This is
  the right call for long spoken episodes, where you replay a sentence far more
  often than you change tracks. Up Next still covers changing episodes.
- The app moves to a scene manifest. The phone's SwiftUI `WindowGroup` stays
  as it is; only a CarPlay scene role is added.

## Data & integrations
- Reads only, through existing stores (`TrackStore`, `LibraryStore`,
  `PlaylistStore`, `BookmarkStore`). One query per list, never per row.
- Writes: bookmarks via `MomentMark.add` (same deduplication as the phone);
  progress via `PlaybackEngine`, as today.
- Starts playback with `PlaybackEngine.play`, not `open`: `open` would push the
  full player onto the phone screen.
- Entitlement `com.apple.developer.carplay-audio`. Apple grants it on request,
  per team, before any build can show up in a car.

## Risks / open questions
- **Entitlement approval** has a lead time and can be refused. Request it
  before writing any code. Without it, nothing can be tested in a real car.
- **Streaming in the car**: cloud episodes need cellular. If an episode isn't
  cached and there's no signal, show an alert, not a silent failure.
- **Cold start in the car**: the phone may be locked. The DB has no explicit
  file protection, so it gets the default (`completeUntilFirstUserAuthentication`),
  which allows this. Never tighten it to `.complete`.
- **China storefront**: CarPlay shows no AI features, so the existing AI
  vendor gating doesn't apply here.
