# TestFlight external testing

App Store Connect → TestFlight → External Testing → **+** group → add the build. First build of a version goes through Beta App Review (~1 day).

## Test Information

Beta App Description (≤4000):

```
Ear to Listen is a podcast player for your own audio files. Point it at a bucket you own (S3, Tencent COS, Alibaba OSS, Azure Blob, Google Cloud Storage) or a folder in Files, and it builds a real library out of what's there: shows, speakers, playlists, topics, and transcripts you can search and edit.

A fresh install is empty. To look around: Settings → Demo mode. It loads a sample library (5 shows, 7 speakers, 12 episodes with timed transcripts, 3 playlists) kept apart from your own; turn it off to go back.

What's in this beta:
• Streams from your own cloud bucket or a local folder; nothing is uploaded to us
• Transcripts on the device (Apple Speech) or with your own cloud key; edit lines in place; search what was said
• Background playback, bookmarks, speakers, playlists, topics
• Backup to iCloud Drive or your own bucket
• Optional AI metadata suggestions with your own API key
• English and Simplified Chinese
```

Feedback Email: `you@example.com`

## Contact Information

| Field | Value |
|---|---|
| First Name | TODO |
| Last Name | TODO |
| Phone number | TODO — yours, with country code (`+1 …`) |
| Email | `you@example.com` |

## Sign-In Information

Sign-in required: **off** (no account in the app). Leave User Name / Password blank.

Review Notes (Beta App Review Information):

```
No account or login. A fresh install is empty by design; please use Settings → Demo mode for a complete sample library with transcripts — no bucket or credentials needed. Speech recognition permission is requested only when the user makes a transcript on the device. Background audio is used for playback.
```

## Per build: What to Test

```
Turn on Settings → Demo mode. Play an episode, lock the phone and check it keeps playing, tap a transcript line to jump, edit a line, search for a phrase that was said, and add a bookmark. If you have a bucket or audio files in Files, connect them and check the library builds. Report anything slow, wrong or confusing with a screenshot via TestFlight.
```
