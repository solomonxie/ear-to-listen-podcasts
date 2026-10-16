# 07 Rest of Library (`Sources/Library`, minus Transcription, AI, Sync, SyncQueueManager, EpisodeSummary)

Files read in full: `ArtworkSidecar.swift`, `ContentAnalyzer.swift`, `DuplicateTitles.swift`, `EpisodeOrder.swift`, `EpisodeRemoval.swift`, `EpisodeUpload.swift`, `FileFingerprint.swift`, `FileKind.swift`, `FlaggedEpisodes.swift`, `FlaggedFix.swift`, `ImageFileStore.swift`, `LibraryMaintenance.swift`, `LibraryNames.swift`, `LibraryNotifications.swift`, `MomentMark.swift`, `OrphanedEpisodes.swift`, `PickedImageFile.swift`, `SourceRefresh.swift`, `SpeakerOrder.swift`, `SyncQueuePolicy.swift`, `SyncScheduler.swift`, `YouTube/SharedYouTubeLinks.swift`, `YouTube/YouTubeCatalog.swift`, `YouTube/YouTubeEpisodes.swift`, `YouTube/YouTubeTranscripts.swift`, `YouTube/YouTubeVideo.swift`. Also read, to confirm findings: `Extensions/Share/YouTubeLinks.swift`, `Extensions/Share/ShareInbox.swift`, `Sync.swift:155-200`, `:280-300`, `TrackStore.numberDuplicateTitles`/`forget`/`find(youTubeVideoID:)`, `LibraryStore.deleteAlbum`/`deleteArtist`/`allAlbums(forArtist:)`, the FK clauses in `Migrations.swift`, `BackupService.unarchive`, `AlbumDetailView` and `EpisodeDetailsPane` artwork setters, `AddYouTubeEpisodeView`, `FlaggedItemsView`, `MiniPlayerBar`, `EarToListenApp` scene-phase hook.

Already covered elsewhere and not repeated: `ArtworkSidecar.adopt` per-copy reads and re-downloads (04 #7), `LibraryNames` main-actor refetch per notification (04 #9), `SourceRefresh` one HEAD per episode (04 #10), `SyncScheduler` retry of failing providers (04 #5), `EpisodeUpload` requeue refusing its own object (04), `ContentAnalyzer` fenced replies (06 #6), `numberDuplicateTitles` re-fetch (01), `YouTubeTranscripts.adopt` overwrite race (01).

**Search is not in this step's scope.** No library search code lives under `Sources/Library` outside `Transcription`. Library search is `Screens/Home/LibrarySearch.swift` (step 11). Phrase search is `Transcription/TranscriptPhraseSearch.swift` (05), and the DB scan is `TranscriptSearch` (01 #10). The fold-once/off-main/CJK/cancellation checks belong to step 11.

Summary: the helpers are small and mostly sound. Image decoding is done right: ImageIO thumbnails off-main and no full-size `UIImage`, and the picker route avoids loading `Data`. YouTube link parsing is strict (11 characters from the ID alphabet, known hosts and paths only). Catalog upload is one query and at most one PUT. The real problems are heuristics that misfire on ordinary input. `DuplicateTitles` treats any title ending in `(n)` as its own numbering and renumbers it. `YouTubeVideo.id(inFileName:)` treats `episode-001.mp3` as a YouTube file. YouTube transcripts are picked alphabetically by language and re-downloaded every sync when they don't parse. There is also lifetime debt: artwork JPEGs are never deleted with their rows, and artwork uploads overwrite the listener's own files out of order. **P0 0 · P1 1 · P2 8 · P3 11**

## P1

**1. `DuplicateTitles` renumbers titles that already carry a real `(n)`. It swaps or closes up the listener's own part numbers.**
`DuplicateTitles.swift:47-77`, `:81-84`; called from `TrackStore.swift:653-671`, `LibraryMaintenance.swift:23`
- `renumbered` groups by `base(of:)`, which strips any trailing ` (digits)`. Then it renumbers every group of more than one by file path. `numberedFrom` is only checked when the group shrinks to one. The type doc (`:20-23`) says a legitimately titled `Encore (2)` "is never touched". That holds only when it is alone in its album.
- Scenario A: an album has `Lecture (1)` in `b.mp3` and `Lecture (2)` in `a.mp3`, from the tags, unedited. The next drain renames `a.mp3` to `Lecture (1)` and `b.mp3` to `Lecture (2)`. The part numbers are now swapped.
- Scenario B: tags `Q&A (1)`, `Q&A (3)` and `Q&A (4)`, with part 2 never downloaded, become `(1)`, `(2)` and `(3)`.
- Scenario C: a tag `Interview` and a tag `Interview (2)` in one album become `Interview (1)` and `Interview (2)`, even though the first was never a duplicate.
- It runs after every drain that did work (04), so a fix by hand sticks only because `metadataEditedAt` then freezes the whole group.
- Fix: only group tracks whose *original* title is identical. That is `numberedFrom ?? title` when `numberedFrom` is set, and the raw `title` otherwise, not `base(of: title)`. A title ending in `(n)` with no `numberedFrom` keeps its own group. `TrackMerge` and `FlaggedEpisodes` can keep using `base(of:)`.

## P2

**2. `YouTubeVideo.id(inFileName:)` matches ordinary podcast names. `episode-001.mp3` skips the bulk path and becomes one queue job.**
`YouTubeVideo.swift:62-69`; `Sync.swift:164-168`, `:287-288`
- Any name whose first 11 characters are `[A-Za-z0-9_-]` and are followed by `-` or `.` counts. That includes `episode-001.mp3`, `episode-042-intro.mp3`, `chapter_one.m4a` and `lecture-0001.mp3`.
- In `Sync`, every such *new* file is sent to `enqueueImport` instead of the one-transaction `registerListed`. A bucket of `episode-001…episode-300.mp3` then becomes 300 per-file jobs under the 100-job cap. That means three full re-listings (04 #4), plus a `find(youTubeVideoID:)` read per file at import, for files that were never YouTube.
- Fix: in the listing pass, load the set of known YouTube IDs once (`youTubeEpisodes()`). Divert a file only when its prefix is in that set. Do the same in `YouTubeTranscripts.byVideoID`.

**3. `DuplicateTitles` numbers by raw `<` on the path, so `(1)` lands on `ep-10` while the list shows `ep-9` first.**
`DuplicateTitles.swift:69`; compare `EpisodeOrder.swift:15-23`
- The doc says numbering "keeps the order the files are actually in". `EpisodeOrder` sorts with `localizedStandardCompare`, and this uses byte order. So `show/ep-10.mp3 < show/ep-9.mp3`, and a run of ten or more same-titled files is numbered out of step with the album page and with playback order.
- Fix: sort with `EpisodeOrder.ordered(group)`.

**4. `YouTubeTranscripts.adopt` re-downloads every candidate that doesn't parse, on every sync, for ever.** (Flagged by 04.)
`YouTubeTranscripts.swift:41-53`, `:12`
- A path that fails `String(data:encoding: .utf8)` (UTF-16 SRT from Windows tools) or parses to no segments is skipped with `continue`. Nothing records the failure, so the next listing downloads it again.
- `json` and `txt` are accepted formats. yt-dlp's `--write-info-json` with the catalog's `<id>-<title>` naming leaves `dQw4w9WgXcQ-title.info.json` (often 0.5–2 MB) beside the video. When it is the only candidate, it is fetched and rejected on every pass. Sync passes run every scheduled interval.
- Fix: keep a small `(path, size/ETag)` failure set per provider, or a column, and skip unchanged failures. Try UTF-16 when the data has a BOM. Exclude `*.info.json`.

**5. YouTube transcript language is chosen alphabetically, not by the listener's language.**
`YouTubeTranscripts.swift:28-33`
- The rank is: untagged first, then format, then the full path. yt-dlp always writes tagged files (`<id>-<title>.en.vtt`, `.zh-Hans.vtt`), so the alphabetically first tag wins. `--sub-langs all` with auto-subs gives the `ab` (Abkhaz) auto-translation. `en,zh-Hans` gives English to a Chinese listener.
- Search then matches the wrong language for that episode, and nothing in the UI says another file was there.
- Fix: rank tagged files by the app language and then the device preferred languages (`Locale.preferredLanguages`). Prefer `*-orig` over translated tracks. Use alphabetical only as the last tie-break.

**6. Artwork uploads overwrite the listener's own `cover.jpg`/`ep.jpg` in their bucket, from unordered detached tasks.**
`ArtworkSidecar.swift:76-98`; `AlbumDetailView.swift:502-505`; `EpisodeDetailsPane.swift:410-413`
- `write` goes through `provider.upload`, which overwrites. Episode audio is protected by never-overwrite (`uploadEpisode`), but images are not. The listener's original (for example a 3000 px `cover.jpg` that Plex also reads) is replaced by the app's 800 px re-encode, and no copy of it is kept.
- Each pick starts its own `Task.detached`, with no ordering and no cancellation. Two quick picks (pick, then AI Draw) can finish in reverse order. The bucket then holds the replaced picture while the app shows the new one. A second device or a reinstall adopts the stale one.
- Fix: before overwriting, skip if the existing object is newer than the app's last write for that key, or keep the original as `cover.orig.jpg`. Serialise uploads per key (latest wins) through one actor.

**7. A shared link whose details can't be read is retried on every foreground, silently and for ever.**
`SharedYouTubeLinks.swift:19-26`; `EarToListenApp.swift:48`
- Any `info` failure re-queues the link. oEmbed answers 401/404 for private, removed or embedding-disabled videos, and those never succeed. Each `.active` (every unlock or app switch) then makes a network request and gives up again. The share extension already said "Added", so the listener never learns that it wasn't.
- Fix: retry only on transport errors. On an HTTP 4xx, either add the episode with a fallback title ("YouTube video \(id)") or drop the link and show a one-time notice.

**8. Artwork and speaker-photo files are never deleted with their rows. The `Artwork` folder only grows.**
`EpisodeRemoval.swift:42`, `:55`, `:64-65`; `TrackStore.swift:304-307`; `LibraryStore.swift:249-255`; `ArtworkSidecar.swift:116-121`, `:131-135`
- Deleting an episode, album or speaker removes the row but not `artworkFileName`/`photoFileName` under Application Support.
- `ArtworkSidecar.adopt` also saves the file *before* its conditional `UPDATE … WHERE artworkFileName IS NULL`. When that matches zero rows (the user set a picture meanwhile, or an overlapping pass won), the new JPEG is orphaned.
- Scenario: a user prunes several hundred-episode albums that came with per-episode art. Tens of MB stay on disk for good. Restore writes every bundled image again (`BackupService.swift:219-222`), referenced or not.
- Fix: one sweep at launch or after deletes. List each image directory once, read every referenced name in one query, and remove the difference. That keeps to the repo's "one listing, then match in memory" rule.

**9. Deleting a speaker deletes their albums even when other speakers' episodes are in them. Those episodes lose their collection.**
`EpisodeRemoval.swift:59-67`; `Migrations.swift:41` (`albumID … onDelete: .setNull`)
- `trackIDs(artistID:)` deletes only this speaker's episodes, but `allAlbums(forArtist:)` deletes every album whose `artistID` is theirs. A guest episode (track `artistID` = guest) in the host's show album survives with `albumID = NULL`. It turns up under Flagged as "No speaker or collection". The album's notes, artwork and profile are gone.
- Fix: delete only albums with no remaining tracks after the episode delete (`DELETE FROM albums WHERE id IN (…) AND NOT EXISTS (SELECT 1 FROM tracks WHERE albumID = albums.id)`). Or delete with the speaker's albums' episodes included, and say so in the dialog.

## P3

- `YouTubeCatalog` keeps one global "shipped" hash. Switching the app-data bucket to another one with the same root never uploads the catalog there until a YouTube episode changes. Key the hash by the catalog's full key. `YouTubeCatalog.swift:78`, `:110-116`
- Dead code:
  - `YouTubeCatalog.State`, `state(dbQueue:)` and the `shippedAtKey` value they read have no callers. `YouTubeCatalog.swift:61-81`, `:116`
  - `ImageFileStore.save(_ data:)`, the variant with no downsampling, has no callers. `ImageFileStore.swift:31-34`
  - `Track.youTubeID` only aliases `youTubeVideoID` (22 call sites). `YouTubeVideo.swift:87`
- `FileKind.audioExtensions` leaves out `m4b`, `aif`, `caf` and `mp4`/`m4v` audio, which AVPlayer plays. An audiobook-style `.m4b` podcast is listed as "File" and never syncs. `alac` is not a file extension. `FileKind.swift:20`
- `MomentMark.count` fetches every bookmark row of a track to count them. It runs on the main actor on each `bookmarksDidChange` from `MiniPlayerBar`. Use `fetchCount`. `MomentMark.swift:24-26`; `MiniPlayerBar.swift:29-31`
- `LibraryMaintenance` sets the done flag before a detached task that first sleeps 5 s. If the app is backgrounded and suspended or killed in that window, the fold/renumber never runs. Set the flag after the work. `LibraryMaintenance.swift:15-26`
- `ArtworkSidecar.lastFound` keeps the full image map per provider and is never pruned when a provider is removed. `ArtworkSidecar.swift:143-152`
- `YouTubeEpisodes.add` upserts the speaker and album before `saveEdit`. A failed save (for example the unique `(providerID, filePath)` index when the Add sheet and a share race) leaves empty rows. Do all three in one write. `YouTubeEpisodes.swift:39-58`
- `EpisodeRemoval` deletes the audio and transcript sidecars but leaves the `ep.jpg` artwork sidecar in the bucket. `EpisodeRemoval.swift:37-40`
- `ImageFileStore.url(for:)` doesn't confine the name to its directory, and `BackupService.unarchive` writes `artwork/<name>` straight from the zip entry. A crafted `artwork/../…` entry writes outside the folder. Reject names containing `/` or `..`. For step 08. `ImageFileStore.swift:24-27`; `BackupService.swift:219-222`
- `FlaggedFixer.tidiedTitle` treats a leading date as a track number: `2024-05-01 Interview` becomes `05-01 Interview`. Require the digit run to be at most 3 characters, or skip `\d{4}-\d{2}`. `FlaggedFix.swift:75`
- `addShared` empties the inbox before processing. If the app is killed mid-loop (oEmbed calls are serial), the unprocessed links are lost. Remove each link only once it is handled. `SharedYouTubeLinks.swift:12`, `:26`

## Test gaps

- `DuplicateTitles.renumbered` with tag titles `X (1)`/`X (2)` in reverse file order, and `X`/`X (2)`. Nothing may change (#1).
- Numbering a run of `ep-1…ep-12` must match `EpisodeOrder` (#3).
- `YouTubeVideo.id(inFileName:)` against `episode-001.mp3`. The sync pass must take the bulk path when no such YouTube episode exists (#2).
- `YouTubeTranscripts.byVideoID` with `.en.vtt`, `.zh-Hans.vtt` and `.info.json` under a Chinese locale (#4, #5).
- `addShared` with oEmbed 404. The link must not come back on every open (#7).
- `EpisodeRemoval.deleteArtist` with a guest episode in the host's album (#9).
- Orphan-image sweep after an episode delete (#8).
