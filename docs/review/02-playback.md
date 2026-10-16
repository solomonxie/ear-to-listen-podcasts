# 02 Playback (`Sources/Playback`)

Summary: no crash paths. The engine trusts its own `isPlaying` and the `Track` snapshot it was handed, so the state drifts from the real player: overlapping loads, failed loads, interruptions, URL-expiry retries and re-tapping the playing episode all leave the wrong audio playing or resume at the wrong spot. Hot-path DB I/O on the main actor and one full download per play are the main performance issues. **P0 0 · P1 5 · P2 6 · P3 14**

## P1

**1. Overlapping loads aren't cancelled, so a slow earlier load can win and play the wrong episode.**
`PlaybackEngine.swift:161`, `:179-207`, `:209-221`
- `play` fires `Task { await loadAndPlay(track:) }` without a token. `loadAndPlay` awaits `cachedURL` twice and `provider.streamURL`, then calls `start(url:track:)` without checking that `track` is still `currentTrack`.
- Scenario: the user taps episode A on a slow connection (presigning or a slow cache actor), then taps B. B resolves first and starts. A resolves next, and `start` replaces B's item with A. The screen and lock screen still say B, and the time observer writes A's playhead into B's `positionMs` every 5 s.
- Fix: keep a `loadGeneration` (or `currentLoad: Task`, cancelled in `play`). After every `await` in `loadAndPlay`, and inside `start`, do `guard generation == loadGeneration, currentTrack?.id == track.id`.

**2. A failed or slow load leaves the previous episode playing under the new title, and its position is saved onto the new episode.**
`PlaybackEngine.swift:143-161`, `:188-189`, `:193-200`, `:204-206`, `:494-519`
- `play` switches `currentTrack` straight away, but the old `AVPlayerItem` keeps playing until `start` runs. On every early return ("No audio left", "No storage provider", "You're offline", a thrown `streamURL`), `start` never runs and nothing pauses `player`.
- Meanwhile `currentTime` still comes from the old item. `persistProgress` writes it under `currentTrack.id`: the 5 s throttled write, plus the forced write from `pause()`.
- Scenario: the user is playing A, goes offline in a tunnel and taps B, which isn't cached. The error banner shows, but A's audio carries on under B's artwork. Pausing then saves A's 37:12 as B's resume point. Even on success, if resolving B takes more than 5 s, A's time is written to B.
- Fix: in `play`, `player.pause()`, `player.removeAllItems()` and `currentTime = 0` before loading. Skip `persistProgress` until the new item is ready (for example, a `loadedTrackID` that `start` sets and `persistProgress` checks).

**3. Interruptions, route changes and stalls aren't handled, so `isPlaying` drifts from the real player.**
`PlaybackEngine.swift:14`, `:121-135`, `:375-399`, `:602-612`. There's no `AVAudioSession.interruptionNotification`, `routeChangeNotification` or `timeControlStatus` observer anywhere in `Sources`.
- AVPlayer pauses itself on a phone call, Siri or an alarm, and when headphones are unplugged (`oldDeviceUnavailable`). `isPlaying` stays `true`, Now Playing keeps rate 1.0, and no progress is force-saved.
- Scenario: AirPods die mid-episode, so audio stops. The lock screen clock keeps counting and shows the "pause" glyph. The first tap on it calls `pause()` on an already paused player, and only the second tap plays. After a phone call ends, playback never resumes, even when the system sends `.shouldResume`.
- Fix: derive `isPlaying` from KVO on `player.timeControlStatus` (or `rate`), and push Now Playing and `persistProgress(force: true)` on every change. Handle `interruptionNotification`: on `.began` mark paused, and on `.ended` with `.shouldResume` call `resume()`. Handle `routeChangeNotification` with `.oldDeviceUnavailable` by calling `pause()`.

**4. The retry after an expired stream URL restarts from the position saved when the episode was opened, which is often 0:00.**
`PlaybackEngine.swift:258-263`, `:311-328`, `:235-254`
- `observeStatus` captures the `track` struct from load time. `handlePlaybackFailure` → `loadAndPlay(track:)` → `seekToStart`. `pendingStart` is nil, so it calls `seekToResumePosition(of: track)` with that stale `positionMs`.
- `hasRetriedCurrentTrack` is only reset by `play`, so a second expiry in the same episode fails outright.
- Scenario: the user opens a fresh episode, listens for 40 minutes, and pauses overnight. The presigned URL has expired by morning. Pressing play makes the item fail, and the retry starts the episode from the beginning, which is exactly the case the code comment is for.
- Fix: before retrying, set `pendingStart = currentTime`. Reset `hasRetriedCurrentTrack` once the new item reaches `.readyToPlay`.

**5. Tapping the episode that's already playing, or going back to one in the queue, resumes from a stale snapshot.**
`PlaybackEngine.swift:143-161`, `:245-254`, `:480-492`; callers such as `HomeView.swift:144` and `AlbumDetailView.swift:67`, none of which check for the same id
- `play(track:)` has no same-id shortcut (only `play(…startingAt:)` has one, `:440`). It reloads the stream and seeks to the passed struct's `positionMs`. That struct comes from a list fetched earlier, and the queue's are from when the queue was built. `recordProgress` doesn't post `libraryDidChange`, so these snapshots never refresh.
- Scenario: the user starts episode 3 from the album page, listens to 30:00, and taps episode 3 again in the same list. Playback rebuffers and jumps back to where it was when the list loaded (or to 0:00). The same happens with `skipToPrevious` and then `skipToNext` within one session.
- Fix: in `play`, if `track.id == currentTrack?.id`, just `resume()`. Otherwise set `pendingStart` from a fresh `positionMs` read (off-main) or from an in-memory `[id: position]` map that `persistProgress` keeps.

## P2

**6. Synchronous DB and file I/O on the main actor in the playback hot path.**
`PlaybackEngine.swift:514-519`, `:303-309`, `:192`, `:342`, `:553-586`, `:670`
- `persistProgress` runs a `dbQueue.write` (fetch and full-row save) on the main actor every 5 s while playing. It's called from the time observer, YouTube `onTime` and the virtual clock.
- `markFinished` makes two writes, `loadAndPlay` makes a `providerStore.all()` read, and `learnVideoLength` makes a write, all on main.
- `updateNowPlayingInfo` runs two `libraryStore` reads, `Data(contentsOf:)` and a full-size `UIImage` decode (or a `LibraryArt` render) on every load and every metadata change.
- With `DatabaseQueue` serialising everything (01 #8), each of these waits behind a sync transaction.
- Scenario: during the first sync of a large bucket, the player UI and transcript scrolling stall every 5 s, and the page opening a new episode hitches on a 3000 px cover decode.
- Fix: send `recordProgress` and `markFinished` to a detached task, as `play` already does, and fetch the provider off-main. Build the artwork off-main with a downsampled `CGImageSource` thumbnail, then publish it.

**7. Every play starts a full background download, and nothing dedupes or cancels it.**
`PlaybackEngine.swift:365-367`; `Cache.swift:70-95`
- `resolvedStreamURL` fires a detached `AudioCache.store` for every uncached episode, in parallel with AVPlayer streaming the same bytes. Skipping does not cancel it.
- The actor re-enters at `await download`, so two stores for the same key both download the whole file, and the last `moveItem` wins.
- Scenario: the user skims 10 two-hour episodes on cellular, a few seconds each. That's about 1 GB of downloads running at once, and `evictIfNeeded` then pushes out episodes downloaded on purpose.
- Fix: track in-flight downloads in a `[key: Task]` map inside the actor and await an existing task instead of starting a second one. Cancel the previous episode's download on `play`, or start it only after N seconds of listening or on Wi-Fi.

**8. A finished episode with no `durationMs` resumes at its own end next time.**
`PlaybackEngine.swift:145-156`, `:289-309`, `:250-254`
- `finishedPlaying` → `markFinished` writes `endMs` (from `duration`), then calls `play(next)`. `play`'s detached "leaving" write then overwrites it with `currentTime`, which is up to 0.5 s short of the end. `resumePosition` only treats the episode as finished when `track.durationMs` is set.
- Scenario: an untagged mp3 plays to the end. The next time it's opened, it starts half a second before the end, ends at once and auto-advances. That's the bug the comment on `markFinished` says it fixes.
- Fix: skip the leaving write when the outgoing track was just finished (pass a flag), or have `resumePosition` fall back to the player's duration.

**9. The Downloaded playlist calls `cachedSize` once per track, because the cache API offers no batch size.**
`Cache.swift:119-124`, `:168-176`, `:188-193`; caller `FixedPlaylistView.swift:107-113`
- Each call is an actor hop, up to five `fileExists` checks (the legacy adoption probe) and a `resourceValues` call. That breaks the CLAUDE.md rule against per-item I/O in a loop.
- Fix: `cachedEntries() -> [String: Int64]`, built from one `contentsOfDirectory(includingPropertiesForKeys: [.fileSizeKey])` call and matched in memory.

**10. `resume()` sets `isPlaying = true` when nothing can play.**
`PlaybackEngine.swift:389-399`, `:289-296`, `:188-200`
- After a failed first load, the player has no item. Pressing play shows "playing" with a frozen clock and no audio. PLAUSIBLE: the same happens after the last episode in the queue ends, because the item sits at its end and `play()` doesn't restart it.
- Fix: if `player.currentItem == nil`, call `loadAndPlay(currentTrack)`. If the item is at its end, seek to zero first, or re-run `play`. With #3's KVO in place, `isPlaying` follows the player instead.

**11. PLAUSIBLE: the remote command set is incomplete.**
`PlaybackEngine.swift:521-546`
- There's no `togglePlayPauseCommand` target. The centre click on wired EarPods and some Bluetooth headsets sends toggle, not play or pause.
- There's no `changePlaybackPositionCommand`, so the lock screen and CarPlay scrubber can't be dragged.
- Fix: add both targets. Toggle calls `togglePlayPause()`, and change-position calls `seek(to: event.positionTime)`.

## Improvements (P3)

- The audio session uses mode `.default`. `.spokenAudio` is the podcast mode: other audio pauses instead of ducking, and it fits CarPlay and AirPods behaviour. The session is never deactivated with `.notifyOthersOnDeactivation`, so music apps can't resume after a pause. `PlaybackEngine.swift:121-135`
- Progress isn't flushed when the app moves to the background or terminates (`EarToListenApp.swift:42-60` doesn't call the engine). A jetsam kill or crash while playing loses up to 5 s. Expose `flushProgress()` and call it on `.background`. `PlaybackEngine.swift:514-519`
- `currentTime` isn't reset on `play`, and `seekToResumePosition` doesn't set it either. `start` pushes Now Playing with the previous episode's elapsed time, and the seek bar shows the old time until the first tick. `PlaybackEngine.swift:215`, `:220`, `:245-248`
- Only `status == .failed` is observed. PLAUSIBLE: a fatal mid-stream error that only posts `AVPlayerItemFailedToPlayToEndTime` (or a permanent stall) never reaches the retry path. `PlaybackEngine.swift:258-281`
- `removeAll` recreates `Downloads` without setting `isExcludedFromBackup` again. Downloads made before the next launch can then go into iCloud backup. `Cache.swift:109-114`
- Eviction edge cases (`Cache.swift:209-228`):
  - A single file larger than the 1 GB cap evicts everything, itself included.
  - The cap is hard-coded.
  - A copy that `localURL` just downloaded on purpose can be evicted by the next store.
  - Files the user dropped into `Documents/Downloads` through the Files app are evicted too.
- Legacy `Caches/AudioCache` entries are never counted or cleaned unless they're touched. Every miss costs five `fileExists` checks. `loadAndPlay` calls `cachedURL` twice per load (`:197`, `:361`), and each call writes the mtime again. `Cache.swift:55-61`, `:168-176`
- A `file://` store calls `copyItem` on the whole episode inside the actor. Every other cache call, including the next play's `cachedURL`, waits for the copy. Copy outside the actor, into a temp file, then move it in. `Cache.swift:72-76`
- Background download failures (disk full, 403) disappear in `try?`, so an episode the user expects to be downloaded silently isn't. `PlaybackEngine.swift:366`
- JS bridge: the `yt` handler and the user script are in every frame (`forMainFrameOnly: false`), including YouTube's iframe and anything it embeds. Any frame can post `{e:'state',s:0}`, which marks the episode listened and auto-advances. Check `message.frameInfo`: accept `blocked` only from a youtube.com origin and everything else only from the main frame. `YouTubeEmbed.swift:42-44`, `:110-137`, `:199-201`
- `YouTubeEmbed.load` returns silently for an invalid ID, after `loadYouTube` has already set `isPlaying = true`. No watchdog starts and the display stays `.loading` forever. `YouTubeEmbed.swift:67-68`; `PlaybackEngine.swift:635-636`
- `seek(to:)` before the embed is ready is dropped (`run` guards `isReady`). The engine has already moved `currentTime`, so it jumps back when the first `time` event arrives. Queue the seek like `playWhenReady`. `YouTubeEmbed.swift:93`, `:105-108`
- When the virtual clock reaches the end, it calls `pause()` instead of `finishedPlaying`, so a blocked video is never marked listened and never advances. `PlaybackEngine.swift:684`
- PLAUSIBLE: YouTube episodes publish no Now Playing info (`:554`, `:627-628`), and WKWebView media is suspended in the background. Locking the phone stops a YouTube episode with no lock-screen controls. If that's intended, document it in the UI.
- Observers (no issue): the periodic time observer, the `libraryDidChange` token and the remote targets are never removed, which is fine for a process-lifetime singleton. The KVO and the end-of-item observer are swapped correctly per item. `WeakHandler` breaks the `WKUserContentController` cycle.

## Test gaps

- Two `play` calls where the first load resolves last (#1).
- A load that fails while an earlier item is playing: the old audio must stop and nothing is written to the new id (#2).
- Interruption began/ended and route change `oldDeviceUnavailable` → `isPlaying` and Now Playing (#3).
- An item failure mid-episode retries at `currentTime` (#4).
- `play` with the current track's id doesn't seek (#5).
- Finishing a track with no `durationMs`: the next resume starts from 0 (#8).
- `AudioCache`: concurrent `store` for one key, an over-cap single file, `removeAll` keeping the backup exclusion, and a batch size listing (#7, #9).
