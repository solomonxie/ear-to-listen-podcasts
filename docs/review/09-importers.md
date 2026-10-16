# 09 Importers and extensions (`Sources/Importers`, `Extensions/Share`)

Files read in full: `Importers/ImportSource.swift`, `Importers/Matcher.swift`, `Importers/Spotify/SpotifyImportSource.swift`, `Extensions/Share/ShareViewController.swift`, `ShareInbox.swift`, `YouTubeLinks.swift`, `Info.plist`, `Share.entitlements`, and the `EarToListenShare` target plus the app target's shared sources in `project.yml`. Also read, to confirm findings: `SharedYouTubeLinks.swift`, `YouTubeEpisodes.existing`, `EarToListenApp` (registration and the `.active` hook), `SettingsViewModel` Spotify lines, `CredentialStore`, `Sources/App/EarToListen.entitlements`, `Tests/MatcherTests.swift`, `Tests/YouTubeEpisodeTests.swift`, `Resources/Localizable.xcstrings`.

Already covered elsewhere and not repeated: `addShared` empties the inbox before processing, so a kill mid-loop loses links (07 P3). Links whose oEmbed fails are retried on every foreground for ever (07 #7). `YouTubeEpisodes.add` leaving empty speaker/album rows on a failed save (07 P3).

**Secrets: clean.** No Spotify client secret anywhere: the flow is PKCE with a user-entered client ID, and both the client ID and the token live in the keychain (`kSecAttrAccessibleAfterFirstUnlock`). Nothing is logged.

**Extension memory: clean.** The extension loads only a `URL` and a `String` per attachment, never file data. A shared `.txt` file arrives as a file URL, so `as? String` is nil and nothing is read. Nothing links GRDB or the app's code beyond the two shared files.

**URL parsing: sound.** `youtu.be`, `watch?v=`, `m.`, `music.`, `www.`, `/shorts/`, `/live/`, `/embed/`, `/v/` and `youtube-nocookie.com` all resolve, the ID must be 11 characters from the ID alphabet, and `YouTubeEpisodeTests` covers each form. Duplicate shares are folded by video ID in `addShared` (`existing(videoID)`), so the same video shared twice, or in two link forms, becomes one episode.

Summary: the share extension is small, light and correct on the happy path. Its weak points are the handoff: it says "Added" without knowing the app will ever see the link, and the inbox is a read-modify-write `UserDefaults` array shared by two processes. Shared text from Chinese apps can fail on full-width punctuation, and the extension's messages are English-only. The Spotify importer and `TrackMatcher` are a music-app leftover: nothing in the app calls them, but they are registered at launch, read from the keychain on every Settings load, and carry several latent bugs. **P0 0 · P1 0 · P2 2 · P3 9**

## P2

**1. The Spotify importer and `TrackMatcher` are dead code that ship in every build.**
`SpotifyImportSource.swift:1-277`; `ImportSource.swift:11-41`; `Matcher.swift:1-74`; `EarToListenApp.swift:24`; `SettingsViewModel.swift:7`, `:36`, `:228-234`
- Nothing calls `authenticate`, `listPlaylists`, `tracks(forPlaylistID:)`, `PlaylistImportSourceRegistry.source(forType:)` or `registeredTypes`. `saveSpotifyClientID` has no caller and no view binds `spotifyClientID`. `TrackMatcher` is called only by `MatcherTests`. It matches music tracks by artist and duration, which this podcast app never needs.
- It still costs: `SpotifyImportSource()` is built at every launch, `SettingsViewModel.load()` does a keychain read for a value no screen shows (and a keychain error there aborts the rest of `load`, so AI keys and the key strategy don't load), the redirect URI is `byomusic://` from another product, and `accounts.spotify.com` is a service that isn't available in the China storefront the app is resubmitting to.
- Scenario: a keychain read failure on the Spotify key (for example `errSecInteractionNotAllowed` before first unlock) leaves Settings with an error and no AI keys listed, for a feature nobody can use.
- Fix: delete `Sources/Importers`, `Tests/MatcherTests.swift`, the registry call, the two Settings members and the README line. Re-add from git if a playlist import is ever designed for podcasts. The bugs in P3 only matter if it is kept.

**2. The extension says "Added" even when the link can't reach the app.**
`ShareInbox.swift:9`, `:12-17`; `ShareViewController.swift:37-39`
- `add` returns silently when `appGroup` is nil (missing or unexpanded `AppGroupIdentifier`), and the view controller shows "Added to Ear to Listen" regardless.
- PLAUSIBLE: when the signed build lacks the App Group capability (a team or profile without it, or an entitlement that didn't expand), `UserDefaults(suiteName:)` still returns an object, but it writes to the extension's private container. The app never sees the link.
- Scenario: a build signed with a profile that doesn't carry `group.<bundle id>`. Every share says "Added", nothing appears, and nothing is logged.
- Fix: make `add` return `Bool`, and check `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:) != nil` before writing. Show "Couldn't add. Open Ear to Listen and paste the link." on failure.

## P3

- PLAUSIBLE: the inbox is a read-modify-write of one `UserDefaults` array from two processes. `takeAll` reads, then removes (`ShareInbox.swift:20-21`), and the app's `retry.forEach(ShareInbox.add)` (`SharedYouTubeLinks.swift:26`) rewrites the array after seconds of oEmbed calls. With the app running in the background for audio, an extension write that lands between the app's read and write is lost. Store one file per link in the App Group container (`<uuid>.link`, written atomically), and have the app list the folder once and delete each file only after handling it. That also fixes 07's kill-mid-loop loss. `ShareInbox.swift:14-23`
- Links pulled from shared text keep trailing punctuation. `/https?:\/\/\S+/` takes `https://youtu.be/dQw4w9WgXcQ。` or `…?v=dQw4w9WgXcQ)` whole, the ID fails `isValidID`, and the listener is told "Only YouTube video links can be added." That is common in text shared from WeChat, Weibo and Telegram. Bare `youtu.be/…` with no scheme is not matched at all. Stop the match at characters outside the URL set (`[A-Za-z0-9\-._~:/?#\[\]@!$&'*+,;=%]+`), and accept `(?:https?://)?(?:[\w-]+\.)?(?:youtube\.com|youtu\.be)/\S+`. `ShareViewController.swift:61`
- The extension's three strings aren't in any catalog the extension bundles (the target has no resources, and `Localizable.xcstrings` doesn't contain them), so a Chinese-language phone gets English in the share card. Add `Resources/Localizable.xcstrings` (or a small extension catalog) to the `EarToListenShare` sources. `ShareViewController.swift:18`, `:39`, `:41`; `project.yml:124-127`
- `NSExtensionActivationSupportsText: true` puts "Ear to Listen" in the share sheet for any selected text in any app, and the web-URL rule for every page in Safari. A dictionary rule can't filter by host, so the URL half is unavoidable, but the text half shows on every share from Notes or Mail and then refuses. If the YouTube app and the main browsers all send a URL item, drop `SupportsText`. If text is needed for chat apps, keep it and say so in a comment. `project.yml:138-140`; `Info.plist:29-35`
- PLAUSIBLE: no timeout or cancel. If a host's `loadItem` never calls back, the card shows "Adding…" until the system kills the extension. Race `sharedLink()` against a 5 s sleep and add a tap-to-dismiss. `ShareViewController.swift:33-45`
- `host.hasSuffix("youtube.com")` also accepts `notyoutube.com` and `evilyoutube.com`. Only the ID is used afterwards, so the effect is cosmetic, but compare `host == d || host.hasSuffix("." + d)`. `YouTubeLinks.swift:23`
- The inbox stores links, not IDs, and doesn't dedupe. The same unreadable video shared three times is three oEmbed calls on every foreground (with 07 #7). Store the video ID and skip ones already in the inbox. `ShareInbox.swift:16`; `ShareViewController.swift:38`
- Spotify, only if kept (#1):
  - `performAuthSession` ignores `session.start()`'s `Bool`. When it returns false (no window, or a second session in flight) the completion never runs, and the continuation hangs for ever. `SpotifyImportSource.swift:148`
  - The class isn't `@MainActor`, so `authenticate` runs off main and starts `ASWebAuthenticationSession` there. `presentationAnchor` then calls `MainActor.assumeIsolated`, which traps if it's called off main (PLAUSIBLE). `authSession`/`presentationContext` are mutated under `@unchecked Sendable` with no lock. Mark the class `@MainActor`. `SpotifyImportSource.swift:21`, `:132-149`, `:269-275`
  - No 401 retry, no 429 `Retry-After`, and two concurrent `get`s each refresh with the same refresh token. `isAuthenticated` is true for a revoked token, so the UI would never offer sign-in again. Refresh once on 401, honour `Retry-After`, serialise refresh in an actor, and sign out when refresh returns 400. `SpotifyImportSource.swift:34-36`, `:154-178`
  - `formEncode` uses `.urlQueryAllowed`, which leaves `+`, `&` and `=` unescaped in form values. Use an unreserved-only set. `SpotifyImportSource.swift:237-243`
  - PLAUSIBLE: a playlist containing a podcast episode, or a local file with no album artists, fails to decode and throws for the whole playlist. Decode items leniently, and pass `additional_types=track`. `SpotifyImportSource.swift:93-109`
  - `TrackMatcher.normalize` cuts at `ft.` anywhere in the string: "Left. Right" becomes "le", "defeat." becomes "de". Match it only as a word (`\bfeat?\.|\bft\.`). `bestMatch` returns a match at any score, including 0. `Matcher.swift:40-44`, `:13-22`

## Tests to add

- `ShareInbox.add` with no App Group reports failure, and the controller shows the failure text (#2).
- Link extraction from `看这个 https://youtu.be/dQw4w9WgXcQ。`, `(https://www.youtube.com/watch?v=dQw4w9WgXcQ)` and `youtu.be/dQw4w9WgXcQ` with no scheme (P3).
- `YouTubeLinks.videoID(in: "https://notyoutube.com/watch?v=dQw4w9WgXcQ")` is nil (P3).
- An inbox written while `addShared` is mid-flight keeps the new link (P3).
