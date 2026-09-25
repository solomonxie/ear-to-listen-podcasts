# Local Database

GRDB/SQLite persistence — `DatabaseManager` opens the on-device DB and runs
`Migrations`; one `*Store` per table handles its own queries. Every Home
shelf reads from here (`LibraryStore`/`TrackStore`/`PlaylistStore`) — there's
no separate mock/demo data layer. `Artist`/`Album`/`Track` keep their
music-era table names, but the UI calls an `Artist` a "Speaker"; `Show` and
`Topic` (added for the podcast domain — a series and its tags, distinct from
`Album`, a curated release) sit alongside them, linked via `showArtists`/
`showTopics`. The `isDemo` flag on those tables is a leftover hook for the
repo-only sample seeder (`DemoData/`, not in the app target); nothing shipped
writes it, and `v27_drop_demo_library` cleared the rows that had it.

## One episode, however many files

`tracks` is one **recording**; `trackFiles` is every **file** it is stored as. The same
episode copied into a second bucket, or sitting in one bucket under two names, is one row
in `tracks` with two in `trackFiles` — so it has one set of marks, one transcript and one
place in every list.

What matches them is `tracks.fingerprint` (`Sources/Library/FileFingerprint.swift`): the
byte count and the running time to the second, not the name and not the provider's ETag —
S3's is an MD5 only for single-part uploads, Google's is base64, Azure's isn't a content
hash at all, and a folder on this device offers none, so no two clouds would ever agree.
Resolved inside `TrackStore.upsert`'s write transaction, which is also what makes two sync
queues draining at once safe.

`tracks.providerID`/`filePath` is the copy it plays from — playback, the cache and the
browser all work in that pair and need exactly one file to open. A copy that vanishes from
a listing is marked lost on its own row, and the episode is only lost once every copy is;
if the copy it played from goes and another is still there, it moves onto that one
(`TrackStore.markLost`, `deleteAll(forProvider:)`). Libraries that already held duplicates
are folded together once by `v32_one_episode_many_files` / `TrackMerge`.

`transcripts` holds one JSON blob of timestamped segments per track, each carrying
the span it covers so a half-finished transcript can be resumed rather than redone;
`transcriptEdits` keeps every correction as its own row — the diff view's history and
the vocabulary hint handed to the next transcription pass
(`Sources/Library/Transcription/`). A corrected line is marked `isEdited`, which is what
keeps the next pass from merging its own version back over it.

`tracks.summary` is what the episode is about, in a few lines — written by the
AI pass over the transcript (`EpisodeSummarizer`) or typed by hand, with
`[12:34]` markers that the card turns into taps that play from there
(`EpisodeSummary`). `terms`/`trackTerms` hold the names and terms that pass
pulled out, with a **count per episode taken by the app** rather than by the
model: a frequency ranking built on a model's own guess at how often it said
something ranks nothing. A term is not a `Topic` — a topic is hand-typed and
belongs to a collection, a term is extracted, belongs to an episode, and there
are dozens per episode.

## Sync Workflow

The one real workflow that touches every store here — a scheduled tick,
manual "Sync Now" (`RemoteBrowserView`), or right after adding a
source (`AddCloudSourceView`/`SettingsSectionView`). It runs in two phases:
listing queues the work and returns; draining does it.

**Phase 1 — list and queue** (returns in seconds, imports nothing):

```
SyncScheduler.start() (foreground poll loop)  /  manual "Sync Now"  /  add-source
        │ ProviderRecord
        ▼
SyncQueueManager.sync(providerRecord:)   ← the one way in
        ▼
Sources/Library/Sync.swift:SyncEngine.sync(providerRecord:)
        │ provider.listFiles(inFolder: nil)   (S3Provider / AzureBlobProvider / … )
        ▼
   for each listed file (TrackFileStore.swift:find(providerID:filePath:))
        │
        ├─ unchanged ──────────────────────────────────────────► skip
        ├─ already queued (SyncJobStore.hasUnfinished) ─────────► skip
        └─ new / changed / was lost ──► SyncJobStore.enqueue(…) ──► `syncJobs`
                                        stops at 100 unfinished
        ▼
TrackStore.swift:markLost(providerID:keepingPaths:)
   any previously-known file missing from this listing ──► isLost = true
        ▼
ProviderStore.swift:updateLastSynced(id:at:) ──► `providers.lastSyncedAt`
        ▼
post .syncQueueDidChange ──► wakes SyncQueueManager.drain()
```

**Phase 2 — drain** (`SyncQueueManager.drain()`, N files at a time):

```
SyncJobStore.dequeueNextPending()  (claims + marks .running in one transaction)
        ▼
SyncEngine.perform(_:providerRecord:) ──► importFileIfNeeded(…)
        │ AVURLAsset metadata (title/artist/album/duration)
        ▼
   Sources/Library/ContentAnalyzer.swift:analyze(filePath:title:artist:album:)
        │ OpenAI key set? guesses better title/artist/album from path + tags, else nil (skip)
        ▼
   LibraryStore.swift:upsertArtist(name:) ──► `artists`
   LibraryStore.swift:upsertAlbum(name:artistID:) ──► `albums`
        ▼
   TrackStore.swift:upsert(track:artistName:albumName:) ──► `tracks` + `trackFiles`
        │                                  same recording already here? ──► just `trackFiles`
        ▼
   SyncJobStore.markDone / markFailed
        ▼
queue empty? ──► connections that stopped at the ceiling are re-listed (phase 1
                 again) until the bucket is done
        ▼
PendingRestore.reapplyAfterSync(dbQueue:)   ← a restore waiting on these tracks
```
