# Bring Your Own Podcasts

Podcast player for iPhone that streams episodes from your own cloud storage
(S3 primary; iCloud/Drive/Dropbox/OneDrive/Aliyun OSS/Tencent COS backlogged),
builds local searchable metadata (shows, speakers, playlists, topics,
transcripts) in SQLite, and syncs that metadata back to remote storage. No
Spotify/Apple Podcasts lock-in.

## Status

No tab bar — one scrollable page (`HomeView`): search up top, then Home/Library
shelves, then Remote, then Settings. Most content runs on in-memory mock data
(`Sources/Screens/Mock/`) plus a few bundled demo audio clips
(`Resources/DemoAudio/`) so playback and live transcript highlighting work out
of the box. The Remote and Settings sections are wired to the real SQLite +
Keychain layer (`Sources/DB/`, `Sources/Providers/`): adding/removing S3 and
local sources, per-source sync frequency + manual "Sync Now", and a foreground
`SyncScheduler` that auto-syncs due sources while the app is active. See
`docs/design/` for the full design doc and phased implementation plan.

## How It's Wired

```
BringYourOwnPodcastsApp.swift:init()
  registers CloudProviders (S3, Local) + SpotifyImportSource
        │
        ▼
ContentView.swift
┌─────────────────────────────────────────────┐
│ HomeView (NavigationStack root)              │──→ Sources/Screens/Home/HomeView.swift
│ ┌───────────────────────────────────────────┐│
│ │ search bar → searchResults                ││──→ inline (same file)
│ │ shelves: Continue/Albums/Playlists/        ││──→ inline (same file)
│ │   Favorites/Speakers/Downloaded/Year/Topic ││
│ │ RemoteSectionView                          ││──→ Sources/Screens/Remote/README.md
│ │ SettingsSectionView                        ││──→ Sources/Screens/Settings/
│ └───────────────────────────────────────────┘│
│ MiniPlayerBar (docked, safeAreaInset bottom) │──→ Sources/Screens/Player/MiniPlayerBar.swift
│   tap → sheet → RealPlayerView               │──→ Sources/Screens/Player/RealPlayerView.swift
│     ├ Details  (tags, file, dates)           │──→ Sources/Screens/Player/EpisodeDetailsPane.swift
│     └ Transcript (lyric-style, editable)     │──→ Sources/Screens/Player/TranscriptPane.swift
└─────────────────────────────────────────────┘
```

The transcript pane is driven by `LiveTranscript`
(`Sources/Library/Transcription/`), which fills in only the stretches of an episode
that have no text yet — on-device (Apple `Speech`) or OpenAI Whisper — saving each
window as it lands and folding the listener's corrections back in as vocabulary hints.

Home's shelves/search read `MockLibraryStore`/`PlaybackMockState`
(`Sources/Screens/Mock/README.md`); Remote and Settings read the real
DB/Provider layers (`Sources/DB/README.md`, `Sources/Providers/README.md`).

## Quickstart

```sh
xcodegen generate
open BringYourOwnPodcasts.xcodeproj
```

Or build from the CLI (add `-skipPackagePluginValidation` — this environment's
Xcode otherwise fails validating the AWS SDK's Smithy code-gen plugin):

```sh
xcodebuild -project BringYourOwnPodcasts.xcodeproj -scheme BringYourOwnPodcasts \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

## Release (TestFlight)

Signing is automatic; set your Apple Developer Team ID for device/archive
builds (simulator builds don't need one):

```sh
DEVELOPMENT_TEAM=YOURTEAMID xcodegen generate
xcodebuild -project BringYourOwnPodcasts.xcodeproj -scheme BringYourOwnPodcasts \
  -configuration Release -archivePath build/BringYourOwnPodcasts.xcarchive \
  -skipPackagePluginValidation archive
xcodebuild -exportArchive -archivePath build/BringYourOwnPodcasts.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

Fill in your team ID in `ExportOptions.plist` before exporting, then upload
`build/export/BringYourOwnPodcasts.ipa` via Transporter or `xcrun altool`.
Xcode Cloud is a no-repo-changes alternative — configure it in App Store
Connect instead of running the commands above.

## Localization

English + Simplified Chinese from the start, via a String Catalog
(`Resources/Localizable.xcstrings`). New UI text should stay in plain
`Text("...")`/`Label("...")` literals so Xcode keeps picking it up; add the
`zh-Hans` translation alongside when you add the English string.

## Screenshots

**Home**
<img src="docs/screenshots/home-page.png" alt="Home" width="200">

**Browse by speaker, year & topic**
<img src="docs/screenshots/sections.png" alt="Browse by speaker, year & topic" width="200">

**Remote & Settings**
<img src="docs/screenshots/settings.png" alt="Remote & Settings" width="200">

**Now Playing**
<img src="docs/screenshots/player.png" alt="Now Playing" width="200">
