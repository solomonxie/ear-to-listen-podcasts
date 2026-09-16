import GRDB

enum Migrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "providers") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("label", .text).notNull()
                t.column("configJSON", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "importSources") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("label", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "artists") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique().collate(.nocase)
            }

            try db.create(table: "albums") { t in
                t.column("id", .text).primaryKey()
                t.column("artistID", .text).indexed().references("artists", onDelete: .setNull)
                t.column("name", .text).notNull()
            }
            try db.create(index: "idx_albums_artist_name", on: "albums", columns: ["artistID", "name"], unique: true)

            try db.create(table: "tracks") { t in
                t.column("id", .text).primaryKey()
                t.column("providerID", .text).notNull().indexed().references("providers", onDelete: .cascade)
                t.column("artistID", .text).indexed().references("artists", onDelete: .setNull)
                t.column("albumID", .text).indexed().references("albums", onDelete: .setNull)
                t.column("filePath", .text).notNull()
                t.column("title", .text).notNull()
                t.column("trackNumber", .integer)
                t.column("durationMs", .integer)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_tracks_provider_path", on: "tracks", columns: ["providerID", "filePath"], unique: true)

            try db.create(table: "playlists") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "local")
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "playlistTracks") { t in
                t.column("playlistID", .text).notNull().indexed().references("playlists", onDelete: .cascade)
                t.column("trackID", .text).notNull().indexed().references("tracks", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistID", "trackID"])
            }

            try db.create(virtualTable: "trackSearchIndex", using: FTS5()) { t in
                t.column("trackID").notIndexed()
                t.column("title")
                t.column("artist")
                t.column("album")
            }
        }

        migrator.registerMigration("v2_sync_settings") { db in
            try db.alter(table: "providers") { t in
                t.add(column: "syncFrequencyMinutes", .integer)
                t.add(column: "lastSyncedAt", .datetime)
            }
            try db.alter(table: "tracks") { t in
                t.add(column: "sizeBytes", .integer)
                t.add(column: "isLost", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3_transcripts") { db in
            try db.create(table: "transcripts") { t in
                t.column("trackID", .text).primaryKey().references("tracks", onDelete: .cascade)
                t.column("segmentsJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4_playback_progress") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "positionMs", .integer)
                t.add(column: "lastPlayedAt", .datetime)
            }
        }

        migrator.registerMigration("v5_sync_queue") { db in
            try db.create(table: "syncJobs") { t in
                t.column("id", .text).primaryKey()
                t.column("providerID", .text).notNull().indexed().references("providers", onDelete: .cascade)
                t.column("filePath", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("sizeBytes", .integer)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Real "Show" (a series) and "Topic" concepts, so Home's shelves can be backed by
        // the synced library instead of mock data. `isDemo` rows come from `DemoDataSeeder`
        // and are wiped/reseeded together, kept apart from anything the user actually synced.
        migrator.registerMigration("v6_shows_and_topics") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "bio", .text)
                t.add(column: "isDemo", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "albums") { t in
                t.add(column: "isDemo", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "playlists") { t in
                t.add(column: "isDemo", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "shows") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("summary", .text)
                t.column("isSaved", .boolean).notNull().defaults(to: false)
                t.column("isDemo", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "topics") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("isDemo", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "showArtists") { t in
                t.column("showID", .text).notNull().indexed().references("shows", onDelete: .cascade)
                t.column("artistID", .text).notNull().indexed().references("artists", onDelete: .cascade)
                t.primaryKey(["showID", "artistID"])
            }

            try db.create(table: "showTopics") { t in
                t.column("showID", .text).notNull().indexed().references("shows", onDelete: .cascade)
                t.column("topicID", .text).notNull().indexed().references("topics", onDelete: .cascade)
                t.primaryKey(["showID", "topicID"])
            }

            try db.alter(table: "tracks") { t in
                t.add(column: "showID", .text)
                t.add(column: "year", .integer)
            }
            try db.create(index: "idx_tracks_show", on: "tracks", columns: ["showID"])
        }

        // Multiple AI keys, each tagged with a vendor, so one dead/rate-limited key
        // doesn't take AI features down entirely — see AiKeyStore/AiRouter.
        migrator.registerMigration("v7_ai_keys") { db in
            try db.create(table: "aiKeys") { t in
                t.column("id", .text).primaryKey()
                t.column("vendor", .text).notNull()
                t.column("requestCount", .integer).notNull().defaults(to: 0)
                t.column("position", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Detects an in-place overwrite (same path, same size) via the provider's content
        // fingerprint instead of relying on size alone — see SyncEngine.importFileIfNeeded.
        migrator.registerMigration("v8_content_hash") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "contentHash", .text)
                t.add(column: "remoteModifiedAt", .datetime)
            }
        }

        // Just a filename under `SpeakerPhotoStore`'s directory, not a full path — portable
        // across devices/reinstalls, and how it travels in a `LibrarySnapshot` backup.
        migrator.registerMigration("v10_speaker_photo") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "photoFileName", .text)
            }
        }

        return migrator
    }
}
