# Local Database

GRDB/SQLite persistence — `DatabaseManager` opens the on-device DB and runs
`Migrations`; one `*Store` per table handles its own queries. This is the
real, wired-up layer (unlike `Sources/Screens/Mock`), but its models
(`Album`/`Artist`/`Track`) still use music-era naming — renaming to the
podcast domain (show/speaker/episode) plus the metadata this app actually
needs (transcripts, topics, file hashes for move-safe re-identification) is
pending, tracked in `docs/design/`.
