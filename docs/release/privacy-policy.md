# Privacy Policy — Ear to Listen

_Last updated: 2026-09-22_

Ear to Listen collects nothing. We run no server, hold no account for you, and receive no
data from the app — there is nowhere for it to go.

## What the app stores

Your library — shows, episodes, speakers, playlists, topics, bookmarks, your own edits and
the artwork you pick — lives in a database file on your device. Episodes you play are kept
as ordinary files in the app's Downloads folder, visible in the Files app. All of it stays
on the phone unless you turn on a backup or export it yourself.

## What leaves the device, and only because you asked

- **Your storage.** The app talks to the bucket or folder you connect — Amazon S3, Tencent
  Cloud COS, Alibaba Cloud OSS, Azure Blob Storage, Google Cloud Storage, or a folder on
  this device — using credentials you supply, to list and read your own files and to write
  back the library metadata and backups you enable. That account is yours; we have no
  access to it.
- **iCloud Drive backup.** Off by default. On, a daily `.zip` of your library data is
  written to your own iCloud Drive folder, in your Apple account and your storage quota.
  Episode audio is never included.
- **Transcription.** On-device by default, using Apple's speech recognition — the audio
  never leaves the phone. If you instead choose OpenAI Whisper, the audio windows being
  transcribed are sent to OpenAI under your own API key.
- **AI suggestions.** Off until you add a key. Titles, show names, notes, transcript text
  and artwork prompts for the episode you are working on are sent to the provider you
  picked — OpenAI, Anthropic, Google, Groq, Mistral, DeepSeek, or xAI — under your own
  account with them. Their privacy policy governs what they do with it.
- **Image search.** Tapping the artwork search link opens your default browser at a search
  page. Nothing from your library is sent anywhere by the app itself.

## Security

Storage credentials and AI keys are kept in the iOS Keychain on this device only. They are
never transmitted to us and are deliberately excluded from every backup the app writes —
restoring a backup on a new phone asks you for them again. All network requests use HTTPS.

## Analytics and advertising

None. No analytics SDK, no crash reporting, no advertising identifiers, no tracking across
apps or websites, no third-party SDKs of any kind beyond a local database library.

## Children

The app is not directed at children and collects no data from anyone.

## Deleting your data

Deleting the app removes the local database and every downloaded episode. Backups you
created in your own iCloud Drive or your own bucket remain yours to keep or delete.

## Changes

Material changes to this policy will be published here with a new date.

## Contact

Questions or requests: https://github.com/solomonxie/ear-to-listen-podcasts/issues
