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
        // the synced library instead of mock data. `isDemo` marked the seeded sample rows,
        // kept apart from anything the user actually synced; v27 drops the last of them.
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

        // Carries the same content-fingerprint/modified-date fields as `CloudFile` so a
        // job's file-changed check has full fidelity, not just size — see
        // `SyncQueueManager.process`.
        migrator.registerMigration("v9_sync_job_change_detection") { db in
            try db.alter(table: "syncJobs") { t in
                t.add(column: "contentHash", .text)
                t.add(column: "remoteModifiedAt", .datetime)
            }
        }

        // Just a filename under `ImageFileStore.speakerPhotos`'s directory, not a full path — portable
        // across devices/reinstalls, and how it travels in a `LibrarySnapshot` backup.
        migrator.registerMigration("v10_speaker_photo") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "photoFileName", .text)
            }
        }

        // Transcripts stop being one all-or-nothing blob: segments carry an end time (in
        // `segmentsJSON`) so a partially transcribed episode can be resumed gap-by-gap,
        // and every user correction is kept as its own row — the audit trail behind
        // "see my edits" and the vocabulary hint fed back into the next request.
        migrator.registerMigration("v11_transcript_editing") { db in
            try db.alter(table: "transcripts") { t in
                t.add(column: "engine", .text)
                t.add(column: "updatedAt", .datetime)
            }

            try db.create(table: "transcriptEdits") { t in
                t.column("id", .text).primaryKey()
                t.column("trackID", .text).notNull().indexed().references("tracks", onDelete: .cascade)
                t.column("segmentStart", .double).notNull()
                t.column("originalText", .text).notNull()
                t.column("editedText", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Episode metadata the listener edited by hand, which has to outrank the embedded
        // tags: a batch export routinely stamps every file with the same title tag, leaving
        // rows indistinguishable. `artworkFileName` is a filename under
        // `ImageFileStore.artwork` (same shape as `artists.photoFileName`), and
        // `metadataEditedAt` marks a row as hand-edited so nothing re-derives over it.
        migrator.registerMigration("v12_episode_metadata_edits") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "notes", .text)
                t.add(column: "artworkFileName", .text)
                t.add(column: "metadataEditedAt", .datetime)
            }
        }

        // Albums get the same hand-editable fields as episodes (see v12) — a collection's
        // name comes from the same embedded tags, and is wrong in the same ways.
        migrator.registerMigration("v13_album_metadata_edits") { db in
            try db.alter(table: "albums") { t in
                t.add(column: "notes", .text)
                t.add(column: "artworkFileName", .text)
                t.add(column: "metadataEditedAt", .datetime)
            }
        }

        // What a running job is doing, not just that it's running — see `SyncJobStage`.
        migrator.registerMigration("v14_sync_job_stage") { db in
            try db.alter(table: "syncJobs") { t in
                t.add(column: "stage", .text)
            }
        }

        // Anything that isn't audio was never an episode. Older builds only filtered on
        // the whole-bucket sync path, so a file tapped in the remote browser — the app's
        // own backup among them — was imported as a track and then kept in sync forever.
        // `FileKind` is the single rule now; this clears what got in before it. Only
        // positively-recognised non-audio goes — an extension-less path might still be
        // audio, and the bundled demo clips are precisely that. Playlist entries and
        // transcripts for the deleted rows go with them.
        migrator.registerMigration("v15_drop_non_audio_tracks") { db in
            let staleIDs: [String] = try Row.fetchAll(db, sql: "SELECT id, filePath FROM tracks")
                .compactMap { row in
                    let filePath: String = row["filePath"]
                    guard FileKind(path: filePath).isKnownNonAudio else { return nil }
                    let id: String = row["id"]
                    return id
                }
            guard !staleIDs.isEmpty else { return }

            // `ON DELETE CASCADE` doesn't fire in here: the migrator runs with foreign keys
            // switched off and only verifies them at the end, so orphaned children would
            // fail the commit rather than be swept up. They go explicitly, children first.
            let placeholders = staleIDs.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(staleIDs)
            for table in ["playlistTracks", "transcripts", "transcriptEdits"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE trackID IN (\(placeholders))", arguments: arguments)
            }
            try db.execute(sql: "DELETE FROM tracks WHERE id IN (\(placeholders))", arguments: arguments)
        }

        // Importing a non-audio file as an episode also minted whatever speaker the
        // metadata guesser made of its filename — "BYOP Backup", out of
        // `byop-backup.json`. v15 removed those tracks, but the library rows they created
        // outlived them, so the bogus speaker stayed on the shelf with no episodes under
        // it. Only rows with nothing left pointing at them and nothing hand-written on
        // them go: a speaker someone wrote a bio or set a photo for is kept even while
        // their episodes are still syncing.
        migrator.registerMigration("v16_drop_orphaned_speakers") { db in
            let orphans = try String.fetchAll(db, sql: """
                SELECT id FROM artists
                WHERE isDemo = 0
                  AND (bio IS NULL OR bio = '')
                  AND (photoFileName IS NULL OR photoFileName = '')
                  AND id NOT IN (SELECT artistID FROM tracks WHERE artistID IS NOT NULL)
                  AND id NOT IN (SELECT artistID FROM albums WHERE artistID IS NOT NULL
                                 AND id IN (SELECT albumID FROM tracks WHERE albumID IS NOT NULL))
            """)
            guard !orphans.isEmpty else { return }

            let placeholders = orphans.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(orphans)
            // Foreign keys are off inside a migration, so `onDelete: .setNull` won't fire.
            // Re-point each affected album at what its own episodes say rather than
            // leaving a dangling id behind.
            try db.execute(sql: """
                UPDATE albums SET artistID = (
                    SELECT t.artistID FROM tracks t
                    WHERE t.albumID = albums.id AND t.artistID IS NOT NULL LIMIT 1
                )
                WHERE artistID IN (\(placeholders))
                """, arguments: arguments)
            try db.execute(sql: "DELETE FROM showArtists WHERE artistID IN (\(placeholders))", arguments: arguments)
            try db.execute(sql: "DELETE FROM artists WHERE id IN (\(placeholders))", arguments: arguments)
        }

        // What language a speaker speaks. Recognizers have to be told — they don't detect
        // it — and the phone's language is no guide at all: an English phone playing a
        // Mandarin show was being handed the en-US model, which doesn't fail, it just
        // returns confident nonsense forever. Kept on the speaker because that's where it
        // actually holds true across every one of their episodes.
        migrator.registerMigration("v17_speaker_language") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "language", .text)
            }
        }

        // What each AI key has actually been used for. A request count says a key is
        // being used; it can't say what it's spending the money on, or that every call
        // through it has been failing since Tuesday.
        migrator.registerMigration("v18_ai_query_history") { db in
            try db.create(table: "aiQueries") { t in
                t.column("id", .text).primaryKey()
                t.column("keyID", .text).notNull().indexed()
                t.column("vendor", .text).notNull()
                t.column("model", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("response", .text)
                t.column("errorMessage", .text)
                t.column("promptTokens", .integer)
                t.column("completionTokens", .integer)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Language is a property of the recording, not of the person: a Mandarin speaker
        // gives a talk in English, and one speaker's albums can each be in a different
        // language. So it's answerable at every level, and the most specific answer wins
        // (episode, then album, then speaker).
        migrator.registerMigration("v19_album_and_episode_language") { db in
            try db.alter(table: "albums") { t in
                t.add(column: "language", .text)
            }
            try db.alter(table: "tracks") { t in
                t.add(column: "language", .text)
            }
        }

        // Favourites and bookmarks are the only two marks a listener leaves on an episode
        // while listening rather than editing it: one says "this one", the other says
        // "this moment". Bookmarks are their own table because there are many per episode
        // and each carries its own time.
        migrator.registerMigration("v20_favorites_and_bookmarks") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "bookmarks") { t in
                t.column("id", .text).primaryKey()
                t.column("trackID", .text).notNull().indexed()
                    .references("tracks", onDelete: .cascade)
                t.column("positionMs", .integer).notNull()
                t.column("note", .text)
                // Comma-separated, like the tags on a photo — a table of its own for two
                // words per bookmark would be a join nobody reads.
                t.column("tags", .text)
                // The words that were being spoken there, copied at the moment the mark
                // was made and editable afterwards: the transcript may be re-run, and the
                // point of the mark is what was said, not what the recogniser now thinks.
                t.column("transcriptText", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // A collection has a year of its own — the season it ran, the year a series was
        // recorded — and it's the sensible default for every episode in it, which is why
        // an episode's own year row falls back to this one rather than sitting empty.
        migrator.registerMigration("v21_album_year") { db in
            try db.alter(table: "albums") { t in
                t.add(column: "year", .integer)
            }
        }

        // A speaker page that only holds a name and one line of bio says almost nothing
        // about whose voice this is. These three are what a listener actually wants to
        // know — the themes, the career behind them, and the longer read — kept as
        // separate columns rather than one blob so a wrong fact can be corrected on its
        // own, and so `knownFor` can stay short enough to sit in a row.
        migrator.registerMigration("v22_speaker_profile") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "knownFor", .text)
                t.add(column: "background", .text)
                t.add(column: "profile", .text)
            }
            // The album equivalent: `notes` stays the sentence or two about what the
            // collection is, and this is the longer write-up under it.
            try db.alter(table: "albums") { t in
                t.add(column: "profile", .text)
            }
        }

        // Shows were a second grouping concept beside `Album`, meant for an ongoing series
        // with its own hosts and subject tags. Nothing in a bucket of audio files ever
        // populated one: a synced library has folders, which become albums. The table sat
        // empty, its screen was unreachable in practice, and the Topics it carried were
        // stranded behind it — a topic could only reach an episode via a show.
        //
        // So topics move onto albums, which is where the real grouping was all along, and
        // the show tables go. Existing links are carried across first: whatever albums a
        // show's episodes belong to inherit that show's topics.
        migrator.registerMigration("v23_topics_on_albums_drop_shows") { db in
            try db.create(table: "albumTopics") { t in
                t.column("albumID", .text).notNull().indexed()
                    .references("albums", onDelete: .cascade)
                t.column("topicID", .text).notNull().indexed()
                    .references("topics", onDelete: .cascade)
                t.primaryKey(["albumID", "topicID"])
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO albumTopics (albumID, topicID)
                SELECT DISTINCT tracks.albumID, showTopics.topicID
                FROM showTopics
                JOIN tracks ON tracks.showID = showTopics.showID
                WHERE tracks.albumID IS NOT NULL
                """)

            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_show")
            try db.alter(table: "tracks") { $0.drop(column: "showID") }
            try db.drop(table: "showTopics")
            try db.drop(table: "showArtists")
            try db.drop(table: "shows")
        }

        // Which model a key should call. Nil means "whatever this vendor's default is",
        // so an existing key keeps behaving exactly as it did — and a new fast/cheap model
        // shipping in a later build reaches every key that never chose one.
        migrator.registerMigration("v24_ai_key_model") { db in
            try db.alter(table: "aiKeys") { t in
                t.add(column: "model", .text)
            }
        }

        // Where to read more about a speaker who has a public page. Stored rather than
        // re-derived, because the AI pass that finds it costs a call and is the one part
        // of a profile that can be checked against the outside world.
        migrator.registerMigration("v25_speaker_link") { db in
            try db.alter(table: "artists") { t in
                t.add(column: "link", .text)
            }
        }

        // Where an episode's transcript sits beside it in the bucket, learned from the
        // listing that syncs it rather than by probing five candidate extensions the
        // first time someone opens it. Null means the last sync saw no sidecar.
        migrator.registerMigration("v26_transcript_sidecar_path") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "transcriptPath", .text)
            }
            // Carried through the queue so a file imported later still arrives knowing
            // where its transcript is — the listing that saw both is long gone by then.
            try db.alter(table: "syncJobs") { t in
                t.add(column: "transcriptPath", .text)
            }
        }

        // The sample library doesn't ship any more — its clips and seeder live in
        // `DemoData/`, outside the app target, for testing only. An install that once
        // loaded it keeps unplayable rows on every shelf, so they go here. Cascades from
        // the provider row take the demo tracks and their transcripts.
        migrator.registerMigration("v27_drop_demo_library") { db in
            try db.execute(sql: "DELETE FROM providers WHERE type = 'demo'")
            try db.execute(sql: "DELETE FROM playlistTracks WHERE playlistID IN (SELECT id FROM playlists WHERE isDemo = 1)")
            try db.execute(sql: "DELETE FROM playlists WHERE isDemo = 1")
            try db.execute(sql: "DELETE FROM albumTopics WHERE albumID IN (SELECT id FROM albums WHERE isDemo = 1)")
            try db.execute(sql: "DELETE FROM topics WHERE isDemo = 1")
            try db.execute(sql: "DELETE FROM albums WHERE isDemo = 1")
            try db.execute(sql: "DELETE FROM artists WHERE isDemo = 1")
        }

        // "Listen Later" — a flag on the episode rather than a seeded playlist row, for
        // the same reason Favorites is one: a list the app owns shouldn't be a row someone
        // can delete, rename or restore a backup over.
        migrator.registerMigration("v28_listen_later") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "listenLater", .boolean).notNull().defaults(to: false)
            }
        }

        return migrator
    }
}
