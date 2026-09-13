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

## Structure

```
Sources/
├── App/          entry point + root view (ContentView → HomeView)
├── Screens/      Home, Player, NowPlaying, Playlists, Remote, Settings, Mock
├── DB/           SQLite persistence — Sources/DB/README.md
├── Providers/    CloudProvider backends — Sources/Providers/README.md
├── Importers/    playlist import sources (Spotify)
├── Library/      Sync engine + SyncScheduler
├── Playback/     PlaybackEngine (AVAudioPlayer wrapper)
└── Services/     Credentials (Keychain)
Resources/        Assets, Localizable.xcstrings, DemoAudio
Tests/            unit tests
docs/             design docs + guides
scripts/          one-off tooling (generate_app_icon.py)
project.yml       XcodeGen spec
```

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

## Localization

English + Simplified Chinese from the start, via a String Catalog
(`Resources/Localizable.xcstrings`). New UI text should stay in plain
`Text("...")`/`Label("...")` literals so Xcode keeps picking it up; add the
`zh-Hans` translation alongside when you add the English string.
