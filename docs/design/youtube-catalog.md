# YouTube catalog and transcripts

The app plays YouTube episodes through YouTube's embed and never fetches anything else
from YouTube. Transcripts for them come from files in the listener's bucket, put there
by a **batch job that lives outside this repo** (the owner's dotfiles,
`scripts/youtube/`). Nothing here depends on it: any tool, or a person, can do its job.

## Contract

| File (beside the backups, `<root>/ear-to-listen-podcasts/`) | Written by | Read by |
|---|---|---|
| `youtube-catalog.json` | the app (`YouTubeCatalog`), when YouTube episodes change | the batch job |
| `youtube-catalog-processed.json` | the batch job, one row per video handled, including ones with no transcript | the batch job only |

Catalog entry: `episodeID`, `videoID`, `url`, `title`, `speaker`, `album`,
`transcriptPath` — a whole bucket key, `<root>/<Speaker>/<Album>/<Title> [<videoID>].vtt`.
Extra languages go beside it as `… [<videoID>].<lang>.vtt`.

The app never reads the processed file and the job never writes the catalog: two writers
on one S3 object lose each other's updates.

## Pickup

Every sync matches `[<videoID>]` in transcript file names anywhere in the bucket against
YouTube episodes with no transcript yet (`YouTubeTranscripts`), so a file still lands if
the speaker or album is renamed after the catalog was written.

## Manual step

Run the job from the dotfiles checkout after adding videos in the app; it needs no
arguments. It reads its bucket credentials from its own `envfile-local` there.
