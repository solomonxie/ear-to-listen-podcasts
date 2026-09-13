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

## Playback Workflow

```
user taps an episode (Home shelf / ShowDetailView / AlbumDetailView / EpisodeListView)
        │
        ▼
PlaybackMockState.swift:play(_:queue:)
        │ sets currentEpisode + queue; looks up episode.audioFileName in the app bundle
        ├─ no bundled clip ──► duration = episode.durationSeconds, isPlaying = false (silent placeholder)
        └─ clip found
              │ AVAudioSession + AVAudioPlayer start
              ▼
        startTimer() ──► async boundary: 0.25s repeating Timer
              │ tick() → progress
              ▼
        updateTranscriptLine() → currentTranscriptLineID
              │ read by (@Published, live)
              ▼
NowPlayingView.swift / MiniPlayerBar.swift — progress bar + highlighted transcript line
        │ clip finishes
        ▼
audioPlayerDidFinishPlaying(_:successfully:) → skipToNext() → play() next episode in queue
```
