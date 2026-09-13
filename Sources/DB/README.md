# Local Database

GRDB/SQLite persistence — `DatabaseManager` opens the on-device DB and runs
`Migrations`; one `*Store` per table handles its own queries. This is the
real, wired-up layer (unlike `Sources/Screens/Mock`), but its models
(`Album`/`Artist`/`Track`) still use music-era naming — renaming to the
podcast domain (show/speaker/episode) plus the metadata this app actually
needs (transcripts, topics, file hashes for move-safe re-identification) is
pending, tracked in `docs/design/`.

## Structure

```
Sources/DB/
├── DatabaseManager.swift    opens byopo.sqlite, runs Migrations
├── Migrations.swift         versioned schema (v1 tables, v2_sync_settings)
├── Models/
│   ├── Album.swift            `albums` table
│   ├── Artist.swift           `artists` table
│   ├── Playlist.swift         `playlists` table
│   ├── Track.swift            `tracks` table (+ sizeBytes, isLost)
│   └── ProviderRecord.swift   `providers` table (+ syncFrequencyMinutes, lastSyncedAt)
├── LibraryStore.swift       Album/Artist queries
├── PlaylistStore.swift      Playlist queries
├── TrackStore.swift         Track queries + per-provider stats/lost-marking
└── ProviderStore.swift      ProviderRecord CRUD + sync-frequency/last-synced updates
```
