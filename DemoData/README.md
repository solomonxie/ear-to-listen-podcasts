# Sample library

What Settings → Demo mode shows: five shows (one in Chinese), seven speakers, twelve spoken
episodes with timed transcripts, summaries, bookmarks, terms, progress, listened /
favourite / listen-later state and three playlists. For trying every feature and for App
Store screenshots and review.

- **Ships in every build**, Release included — the toggle is for reviewers too.
- **Your library is never touched.** Switching on copies the live database aside
  (`Application Support/demo/`) and swaps in a fresh sample one; switching off swaps it
  back. Backups, the change log and first-run restore pause while it's on.
- **Credentials, non-Release only:** `cp .env.demo.example .env.demo`, fill in a bucket
  and/or AI key, then `make ios`. `scripts/demo-secrets.sh` bundles them into Debug builds;
  demo mode adds them as a source and a key and removes them from the Keychain on the way
  out. Release never carries or reads them — demo mode there is the bundled data alone.
- **Changing the content:** edit `demo-library.json` (a summary's `{3}` becomes the start
  time of line 3), then `venv/bin/python DemoData/make-audio.py` to re-speak the audio with
  macOS `say` and re-time the transcripts.
