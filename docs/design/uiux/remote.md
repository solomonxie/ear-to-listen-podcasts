# Remote — sources and folder browser

## Section on Home  `Sources/Screens/Remote/RemoteSectionView.swift`

```
 Remote                                        ⊕   → Add S3 Bucket sheet
 Sync only fetches metadata — episodes download when you listen.
 ┌───────────────────────────────────────────────┐
 │ ☁  slmx-archives2                          ›  │ long-press → Delete !
 │ 44 s3://slmx-archives2/bible-audio/           │ ← tells two connections to
 │    Active · synced 9 hours ago                │   the same bucket apart
 └───────────────────────────────────────────────┘
 [ ⟳ Sync Now ] [ 🕐 Manual ▾ ] [ 📥 Queue (12) ]
   ↑ spinner replaces the icon, label stays "Syncing" — a button that
     resizes as you press it shoves its neighbours sideways
 Auto sync app data to this bucket              ─●   ← ordinary switch, own
 Replaced when it changes. Last: Sep 16, 2026 9:02 AM.   row, not a 3rd pill
 Added 42, 0 missing, 1,226 files found.        ← after a manual sync
 ─────────────────────────────────────── (inset 68pt, between sources)

 empty   No remote sources yet. Add an S3 bucket to browse and sync
         episodes from.
```

App-data hint, all four readings:

```
 off      App data isn't kept here — it stays on this device.
 on,new   One zip of your playlists, edits and transcripts. Never your
          episode audio.
 on       Replaced when it changes. Last: Sep 16, 2026 9:02 AM.
 failed   Last app-data backup failed: <vendor's own words>
```

## Folder browser  `Remote/RemoteBrowserView.swift`

One screen, pushing itself per subfolder. Every level is identical.

```
 ‹ Back        slmx-archives2                  ⋯
 📁 bible-audio                             ›     → push, deeper prefix
 📁 2026                                    ›
 〰 ep-004.mp3                    24.1 MB   ⓘ     audio = primary text
 📄 ep-004.txt                     4 KB    ⓘ     everything else = secondary
 ───────────────────────────────────────────────
 12 files here · 412 MB · 2 folders · 361 synced   ← footer, this folder only
                                    ⟳ Syncing…    ← tappable → queue
```

Leads with what is in the folder *now* (a live `listDirectory`), because that
is what the list above shows; what this device has synced is the follow-up.

```
 ⋯ menu   Last synced: 9 hours ago      ← text, not a control
          ☰ Queue
          ──────────
          🗑 Delete Connection  !        → confirmation dialog
```

Sync Now and the frequency picker are **not** here — they are decisions about
a connection, so they live on the source's own row above.

### States

```
 loading   ⟳ centred, and the footer is withheld too — a fast local stats
           read above an empty list reads as an empty folder
 empty     This folder is empty.
 offline   ⚠ You're offline — showing what's already synced.
           footer: Last synced · 361 synced
 error     ⚠ Couldn't list this folder: <AWS message>
 fallback  Couldn't reach this source, and nothing here has been synced yet.
 tapping   ⟳ on the row while an unknown file is imported before it plays
```

## Tapping a file, by kind

```
 audio  ──▶ plays (imported first if unknown), queue = the folder's audio
 text   ──▶ preview sheet
 other  ──▶ info sheet only — a backup or a cover image is not an episode
```

```
        MP3 audio
 File      ep-004.mp3
 Size      24.1 MB
 Modified  Sep 12, 2026 4:13 PM
 Kind      MP3 audio
 ─────────────────────────────────────────────
 Tapping this file plays it directly — if it isn't already synced, it's
 imported first so future syncs recognize it.
 (non-audio) Not an audio file, so it's never synced as an episode. It's
 listed because it's in this folder.
```

## Add S3 bucket  `Settings/AddS3ProviderView.swift`

```
 Cancel        Add S3 Bucket            Save·    · until bucket+keys filled
 ┌ FILL FROM AN EXISTING CONNECTION ───────────┐  (only when there are any)
 │ slmx-archives2                              │
 │ s3://slmx-archives2/bible-audio/            │
 ├ S3 Bucket (paste info to add) ──────────────┤  ← the "(…)" is the button
 │ Bucket name                                 │
 │ Folder path (e.g. podcasts/)                │
 │ Access Key ID                               │
 │ Secret Access Key            ••••••         │
 │ Only files under this folder in the bucket  │
 │ are used. Leave it empty for the whole      │
 │ bucket — a trailing / is added for you.     │
 │ Region is detected automatically.           │
 └─────────────────────────────────────────────┘
 Tip: create an IAM user scoped to read-only access on this bucket
 rather than reusing your main AWS credentials.
 How to create a bucket and set permissions →

 tap (paste info to add) ↓

 ┌ S3 Bucket (back to fields) ─────────────────┐  fields are REPLACED
 │ bucket: my-bucket                           │
 │ folder: podcasts/                           │
 │ access_key_id: AKIA…                        │
 │ secret_access_key: …                        │
 │ `:` or `=`, any spelling of the key names.  │
 │ Fills the fields as you paste. Region is    │
 │ still detected automatically.               │
 └─────────────────────────────────────────────┘
 one real paste ⇒ snap back to the filled fields; typing by hand keeps
 the box open

 saving   ⟳ in place of Save — tests the bucket, persists only on success
 error    ⊗ <AWS message>            ← inline section, never an alert
```
