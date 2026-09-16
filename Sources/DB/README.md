# Local Database

GRDB/SQLite persistence — `DatabaseManager` opens the on-device DB and runs
`Migrations`; one `*Store` per table handles its own queries. Every Home
shelf reads from here (`LibraryStore`/`TrackStore`/`PlaylistStore`) — there's
no separate mock/demo data layer. `Artist`/`Album`/`Track` keep their
music-era table names, but the UI calls an `Artist` a "Speaker"; `Show` and
`Topic` (added for the podcast domain — a series and its tags, distinct from
`Album`, a curated release) sit alongside them, linked via `showArtists`/
`showTopics`. `DemoDataSeeder` (`Sources/Library`) populates all of these
with sample rows on first launch (or via "Reset Demo Data"), tagged
`isDemo = true` so they can be wiped and reseeded without touching anything
actually synced.

`transcripts` holds one JSON blob of timestamped segments per track, each carrying
the span it covers so a half-finished transcript can be resumed rather than redone;
`transcriptEdits` keeps every correction as its own row — the diff view's history and
the vocabulary hint handed to the next transcription pass
(`Sources/Library/Transcription/`).

## Sync Workflow

The one real workflow that touches every store here — a scheduled tick,
manual "Sync Now" (`RemoteBrowserView`), or right after adding a
source (`AddS3ProviderView`/`SettingsSectionView`):

```
SyncScheduler.start() (foreground poll loop)  /  manual "Sync Now"  /  add-source
        │ due ProviderRecord
        ▼
Sources/Library/Sync.swift:SyncEngine.sync(providerRecord:)
        │ provider.listFiles(inFolder: nil)   (S3Provider / LocalFilesProvider)
        ▼
   for each file already known (TrackStore.swift:find(providerID:filePath:))
        │
        ├─ unchanged ─────────────────────────────────────────► skip
        └─ size changed / was lost ──► TrackStore.swift:refresh(id:sizeBytes:isLost:)
        │
   for each new file
        │ AVURLAsset metadata (title/artist/album/duration)
        ▼
   Sources/Library/ContentAnalyzer.swift:analyze(filePath:title:artist:album:)
        │ OpenAI key set? guesses better title/artist/album from path + tags, else nil (skip)
        ▼
   LibraryStore.swift:upsertArtist(name:) ──► `artists`
   LibraryStore.swift:upsertAlbum(name:artistID:) ──► `albums`
        ▼
   TrackStore.swift:upsert(track:artistName:albumName:) ──► `tracks`
        ▼
TrackStore.swift:markLost(providerID:keepingPaths:)
   any previously-known file missing from this listing ──► isLost = true
        ▼
ProviderStore.swift:updateLastSynced(id:at:) ──► `providers.lastSyncedAt`
```
