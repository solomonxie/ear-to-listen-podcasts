# YouTube episodes, the catalog, and files in the bucket

A YouTube episode is a video's ID plus everything the listener adds to it. It plays as
YouTube's embedded video — unless the listener's own storage holds files for it, which
are then used like any other episode's.

## Matching

Files named with the video ID in brackets, anywhere in a connected bucket:

| File | Effect on the next sync |
|---|---|
| `… [<videoID>].vtt` (`.srt`, `.lrc`, `.json`, `.txt`; `.<lang>.vtt` for more languages) | becomes the episode's transcript, if it has none (`YouTubeTranscripts`) |
| `… [<videoID>].mp3` (any audio type) | becomes the episode's audio: it plays from the file — background, lock screen, CarPlay — and transcripts beside it work as for any episode (`TrackStore.attach`) |

The ID is the whole match, so renaming the speaker or album later doesn't strand a file.
If the audio file goes away, the episode plays the video again.

## Catalog

`<root>/ear-to-listen-podcasts/youtube-catalog.json`, beside the backups, rewritten when
YouTube episodes change (`YouTubeCatalog`): per episode `episodeID`, `videoID`, `url`,
`title`, `speaker`, `album`, and where its files go — `transcriptPath` and `audioPath`,
`<root>/<Speaker>/<Album>/<Title> [<videoID>].<ext>`.

It's for whatever the listener does outside the app — by hand or with their own tools,
which live elsewhere. The app only writes this file; anything such a tool keeps beside
it (e.g. a list of what it has handled) is its own, never read or written here.
