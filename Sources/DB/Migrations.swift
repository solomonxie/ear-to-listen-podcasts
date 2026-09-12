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

        return migrator
    }
}
