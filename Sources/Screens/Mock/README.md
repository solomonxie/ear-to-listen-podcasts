# Mock Data Layer

In-memory placeholder domain (shows, episodes, speakers, playlists, remote
sources, transcripts) for the UI/UX pass — no GRDB, no `CloudProvider`, no
network. `MockLibraryStore` seeds from `MockData`'s static samples and resets
via Settings ▸ Demo Data. `PlaybackMockState` drives real `AVAudioPlayer`
playback over the bundled clips in `Resources/DemoAudio/`, so play/pause/seek
and transcript highlighting are genuine, not simulated.

Superseded once screens wire up to the real `Sources/DB` schema and
`Sources/Providers` — until then, most screens under `Sources/Screens/`
depend on this instead.

## Structure

```
Sources/Screens/Mock/
├── MockModels.swift        Speaker, PodcastShow, PodcastEpisode, TranscriptLine, Topic, PlaylistUI, RemoteEntry
├── MockData.swift          static sample data + MockLibraryStore (ObservableObject, resettable)
└── PlaybackMockState.swift AVAudioPlayer-backed playback over Resources/DemoAudio clips
```
