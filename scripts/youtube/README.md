# YouTube Subtitles

Saves a YouTube video's subtitles as `.vtt`, for a YouTube episode's transcript **Load**
button. Runs on a Mac with yt-dlp, never in the app.

- Hand-made subtitles when there are some, YouTube's automatic ones otherwise.
- Auto-captions cleaned: one cue per spoken line, no rolling repeats or word tags.
- A video or a whole playlist.
- Files land in **Files › iCloud Drive › Ear to Listen › Subtitles** when this Mac has the
  app's iCloud folder, so the phone sees them; `./subtitles` otherwise.

## Run

```sh
/opt/homebrew/bin/python3.12 -m venv venv && venv/bin/pip install -r scripts/youtube/requirements.txt
venv/bin/python scripts/youtube/subtitles.py "https://youtu.be/<id>" [--langs en,zh-Hans] [--out DIR]
venv/bin/pytest scripts/youtube/subtitles.py
```

Pulling subtitles this way is against YouTube's terms; it's for your own copies.
YouTube rate-limits (`HTTP 429`) after many requests — wait, or ask for fewer languages.
