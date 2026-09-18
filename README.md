# Ear to Listen Podcasts

Podcast player for iPhone that streams episodes from your own cloud storage
(S3 primary; iCloud/Drive/Dropbox/OneDrive/Aliyun OSS/Tencent COS backlogged),
builds local searchable metadata (shows, speakers, playlists, topics,
transcripts) in SQLite, and syncs that metadata back to remote storage. No
Spotify/Apple Podcasts lock-in.

## Status

No tab bar — one scrollable page (`HomeView`): search up top, then Home/Library
shelves, then Remote, then Settings. A fresh install starts empty — nothing
appears in the library that the user didn't put there — with an optional sample
library (`DemoDataSeeder`, bundled clips under `Resources/DemoAudio/`) loadable
from the empty state or Settings for looking around first. Everything is wired
to the real SQLite + Keychain layer (`Sources/DB/`, `Sources/Providers/`): adding/removing S3 and
local sources, per-source sync frequency + manual "Sync Now", and a foreground
`SyncScheduler` that auto-syncs due sources while the app is active. See
`docs/design/` for the full design doc and phased implementation plan.

## How It's Wired

```
EarToListenApp.swift:init()
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
│     ├ Transcript (lyric-style, editable)     │──→ Sources/Screens/Player/TranscriptPane.swift
│     └ Edit (title/speaker/art/notes, AI)     │──→ Sources/Screens/Player/EpisodeEditView.swift
└─────────────────────────────────────────────┘
```

Every episode is listed as title + file path, since a whole folder of files routinely
shares one embedded title tag and the path is then all that separates them. Anything a
tag got wrong is editable (`EpisodeEditView`, from the player or a long-press on any
row) — artwork included — and `EpisodeMetadataSuggester` will draft those fields from
the episode's transcript, once that transcript is complete (a half-done one only
describes the part that got done). A whole album can be sorted out in one pass
(`AlbumMetadataSuggester`, from the album page) — it reads only the transcripts already
on the phone, downloads nothing, and every proposed change is reviewed before it lands. Edits stand: sync only reads tags for files the
library doesn't know yet, and they travel in a `LibrarySnapshot` backup.

The transcript pane is driven by `LiveTranscript`
(`Sources/Library/Transcription/`), which fills in only the stretches of an episode
that have no text yet — on-device (Apple `Speech`) or OpenAI Whisper — saving each
window as it lands and folding the listener's corrections back in as vocabulary hints.
Each window is decoded straight out of the source with `AVAssetReader` and handed over
as a 16 kHz mono WAV, reading byte ranges in place: no full download first, and no
container the recognizer might refuse.

Home's shelves/search, Remote and Settings all read the real DB/Provider layers
(`Sources/DB/README.md`, `Sources/Providers/README.md`) — sample content flows
through the same tables, so it appears exactly as a synced source would.

The app's own data — playlists, hand edits and their images, transcripts and
corrections — is backed up automatically to either or both of two places
(`Sources/Backup/README.md`): the listener's own iCloud Drive (one switch in
Settings, nothing to set up, visible in Files under "Ear to Listen") and the
connected S3 bucket (a switch on that connection's row). Episode audio is never
uploaded. Deleting and reinstalling the app puts the data back by itself on
first launch, and the parts that need the episode files re-link themselves as
the next sync fetches them.

## Quickstart

```sh
xcodegen generate
open EarToListen.xcodeproj
```

Or build from the CLI (add `-skipPackagePluginValidation` — this environment's
Xcode otherwise fails validating the AWS SDK's Smithy code-gen plugin):

```sh
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build
```

## Release (TestFlight)

Signing is automatic against the team in `project.yml`
(`DEVELOPMENT_TEAM`) — change that one line to your own Apple Developer Team
ID. Simulator builds don't need one. iCloud backup needs the
`iCloud.com.solomonxie.eartolisten` container entitlement
(`Sources/App/EarToListen.entitlements`), which needs a paid developer
account — a free-team build still builds and runs, and the iCloud row in
Settings reports itself unavailable instead of pretending:

```sh
xcodegen generate
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -configuration Release -archivePath build/EarToListen.xcarchive \
  -skipPackagePluginValidation archive
xcodebuild -exportArchive -archivePath build/EarToListen.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

Fill in your team ID in `ExportOptions.plist` before exporting, then upload
`build/export/EarToListen.ipa` via Transporter or `xcrun altool`.
Xcode Cloud is a no-repo-changes alternative — configure it in App Store
Connect instead of running the commands above.

## Localization

English + Simplified Chinese from the start, via a String Catalog
(`Resources/Localizable.xcstrings`). New UI text should stay in plain
`Text("...")`/`Label("...")` literals so Xcode keeps picking it up; add the
`zh-Hans` translation alongside when you add the English string.

## Screenshots

| Home | Browse by speaker, year & topic |
|:---:|:---:|
| <img src="docs/screenshots/home-page.png" alt="Home" width="200"> | <img src="docs/screenshots/sections.png" alt="Browse by speaker, year and topic" width="200"> |
| **Remote & Settings** | **Now Playing** |
| <img src="docs/screenshots/settings.png" alt="Remote and Settings" width="200"> | <img src="docs/screenshots/player.png" alt="Now Playing" width="200"> |
