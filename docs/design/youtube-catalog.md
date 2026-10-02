# YouTube episodes, the catalog, and files in the bucket

A YouTube episode is a video's ID plus everything the listener adds to it. It plays as
YouTube's embedded video — unless the listener's own storage holds files for it, which
are then used like any other episode's.

## Matching

Files whose name starts with the video ID, then `-` or the extension, anywhere in a
connected bucket — `dQw4w9WgXcQ-never-gonna-give-you-up.mp3`:

| File | Effect on the next sync |
|---|---|
| `<videoID>-<title>.vtt` (`.srt`, `.lrc`, `.json`, `.txt`; `.<lang>.vtt` for more languages) | becomes the episode's transcript, if it has none (`YouTubeTranscripts`) |
| `<videoID>-<title>.mp3` (any audio type) | becomes the episode's audio: it plays from the file — background, lock screen, CarPlay — and transcripts beside it work as for any episode (`TrackStore.attach`) |

The ID is the whole match: the title after it, and the folders above it, can be renamed
freely. Names are slugs (`YouTubeVideo.slug`) — lowercase, hyphens for spaces and
punctuation, letters of any script kept.
If the audio file goes away, the episode plays the video again.

## Catalog

`<root>/ear-to-listen-podcasts/youtube-catalog.json`, beside the backups, rewritten when
YouTube episodes change (`YouTubeCatalog`): per episode `episodeID`, `videoID`, `url`,
`title`, `speaker`, `album`, and where its files go — `transcriptPath` and `audioPath`,
`<root>/<speaker>/<album>/<videoID>-<title>.<ext>`.

It's the listener's checklist for adding files by hand. The app only writes this file;
anything else the listener keeps in that folder is theirs, never read or written here.
