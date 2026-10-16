# 15 Tests (`Tests`)

Summary: 49 files, about 5.5k lines, all XCTest. The tests are good on pure logic: parsers, naming, coverage maths, SAS/V4 URLs and store queries on an in-memory DB. They are thin wherever the P0/P1 findings live: none of the 5 P0s and only a handful of the 44 P1s has a test that could fail on the bug. Three things explain most of the misses. Every DB is migrated from empty. The re-apply and sync tests never put a user edit or a bad listing between two passes. The fakes can only answer "found" or "not found". Two tests assert the buggy behaviour as correct (an empty listing marks every episode lost; tag-carried "(n)" titles count as a run), so the fixes will break them. The tests are app-hosted, so some of them write into the real app's image folders and keychain. **P0 0 · P1 2 · P2 8 · P3 6**

Files read in full: `SameFileTests`, `BackupServiceTests`, `CloudBackupTests`, `CloudBackupFolderTests`, `SyncEngineTests`, `EpisodeUploadTests`, `AzureBlobTests`, `SigV4Tests` (top half; parser half skimmed), `S3ProviderTests`, `GoogleCloudStorageTests`, `BucketEndpointTests`, `LocalFilesProviderTests`, `CloudWriteTests`, `LocalBackupsTests`, `BackupArchiveNameTests`, `TranscriptMergeSplitTests`, `DuplicateTitlesTests`, `CarLibraryTests`, `PlaybackEngineTests`, `KeyboardDismissalTests`, `ImageFileStoreTests`, `AudioCacheNamingTests`, `MatcherTests`, `DemoDataSeederTests`, `AiVendorStorefrontTests`, `ArtworkSidecarTests`, `EarToListenTests`, `TranscriptLanguageTests`. The other 21 were skimmed for structure (test names, setup, fakes): `TranscriptTests`, `SyncJobStoreTests`, `YouTubeEpisodeTests`, `RemoteFileGroupTests`, `EpisodeSummaryTests`, `TermStoreTests`, `TranscriptSearchTests`, `AiQueryHistoryTests`, `AlbumMetadataSuggesterTests`, `EpisodeMetadataSuggesterTests`, `ProfileSuggesterTests`, `LibrarySearchTests`, `BookmarkGroupTests`, `BookmarkInsightsTests`, `BucketConnectionDraftTests`, `CloudProviderDirectoryTests`, `FlaggedEpisodesTests`, `ListenHistoryTests`, `SpeakerOrderTests`, `SpokenLanguageTests`, `EpisodeOrderTests`. Also read the test target in `project.yml` and, to write concrete tests, `TrackMerge.foldDuplicates`, `BackupService.unarchive`, `AzureSharedKey.canonicalizedResource`, `S3RestClient.url(key:)`, `CarPlayController.observe` and the migration ids.

Setup facts that matter below:
- Every DB is `DatabaseQueue()` (in-memory) plus `Migrations.migrator().migrate(dbQueue)` from empty. No test runs `migrate(_:upTo:)`, and there is no fixture database.
- `EarToListenTests` is a `bundle.unit-test` that depends on the app (`project.yml:158-172`), so XcodeGen hosts it in the app. Every run boots the real app: `DatabaseManager.shared`, the observers, `AutoBackup`. The comment at `KeyboardDismissalTests.swift:18` confirms the tests also run on the phone.
- No test uses the network, `sleep` or `Task.sleep`. Fixed dates are used where signatures need them.

## Coverage map

| Sources area | Covered by | Not covered |
|---|---|---|
| `DB` stores | `SameFileTests` (TrackStore, TrackFileStore, TrackMerge, FixHistory, neglect), `SyncJobStoreTests`, `TermStoreTests`, `TranscriptSearchTests`, `TranscriptMergeSplitTests`, `AiQueryHistoryTests`, `AiVendorStorefrontTests` (AiKeyStore), `TrackUpsertRaceTests`, `ScanThenTagsTests`, `ScanDuplicateFoldTests` | `DatabaseManager` (open, `try!`, checkpoint), upgrade migrations with data, `PlaylistStore` beyond create/add, `LibraryStore.updateAlbum`, `saveEdit` under concurrent writes |
| `Backup` | `BackupServiceTests`, `CloudBackupTests`, `CloudBackupFolderTests`, `BackupArchiveNameTests`, `LocalBackupsTests` (prune, ChangeLog mark), `ZipArchive` via one round trip | `DatasetRestore`, `PendingRestore`, `FirstRunRestore`, `AutoBackup`, `CloudDrive`, `LocalBackups.copyDatabase`, `unarchive` with hostile names, `apply` failure part-way |
| `Providers` | `SigV4Tests` (encoding, canonical query, S3 list XML), `AzureBlobTests` (SharedKey on a listing, SAS, list XML), `GoogleCloudStorageTests` (key parsing, V4 URL), `S3ProviderTests` / `BucketEndpointTests` (config only), `LocalFilesProviderTests`, `CloudWriteTests`, `CloudProviderDirectoryTests`, `BucketConnectionDraftTests` | `S3RestClient` URL building, `S3Provider` region detection, `AzureBlobProvider` operations and escaped-path signing, GCS provider operations, `Provider.uploadEpisode` error mapping, `NetworkMonitor`, `CredentialStore` |
| `Library` sync | `SyncEngineTests` (`sync`, `perform` via a hand-rolled drain), `EpisodeUploadTests`, `ArtworkSidecarTests` | `SyncQueueManager` (drain, `fillTagReads`, retry, per-provider serialisation), `SyncScheduler`, `SourceRefresh`, `EpisodeRemoval`, `LibraryMaintenance`, threading of `libraryDidChange` |
| `Library/Transcription` | `TranscriptTests` (coverage, merge, lines, file formats, locale, `padded`), `TranscriptLanguageTests`, `SpokenLanguageTests`, `RemoteFileGroupTests` (sidecar index), `YouTubeEpisodeTests` (`TimestampedText`, `segments`) | `TranscriptRunner` instance behaviour (`run`, resume, upload, `isUploading`), `AppleSpeechTranscriber.transcribe`, `OpenAIWhisperTranscriber`, `AudioWindowFile`, `TranscriptPhraseSearch` |
| `Library/AI` | `EpisodeSummaryTests`, `EpisodeMetadataSuggesterTests`, `AlbumMetadataSuggesterTests`, `ProfileSuggesterTests`, `BookmarkInsightsTests`, `AiQueryHistoryTests` (pricing) | `AiRouter` (token limits), all four chat clients' request bodies, `ArtworkSuggester`, `ContentAnalyzer` |
| `Library` other | `DuplicateTitlesTests`, `EpisodeOrderTests`, `FlaggedEpisodesTests`, `FlaggedFixTests`, `SpeakerOrderTests`, `ImageFileStoreTests`, YouTube catalog/filing | `MomentMark`, `PickedImageFile`, `LibraryNames`, `SharedYouTubeLinks` |
| `Playback` | `PlaybackEngineTests` (one static artwork helper), `AudioCacheNamingTests` | All of `PlaybackEngine`'s state machine, `Cache` I/O, `YouTubeEmbed` |
| `CarPlay` | `CarLibraryTests` (window and detail text) | `CarPlayController`, `CarPlaySceneDelegate`, `CarArtwork` |
| `App` | `KeyboardDismissalTests`, `AppLanguage.initial` | Everything else (lifecycle, `ContentView`, `AppMode`) |
| `Screens` (56 files) | Pure helpers only: `LibrarySearch`, `BookmarkGroup`, `ListenHistorySection`, `RemoteFileGroup`, `AddYouTubeEpisodeView` filing, `FixedPlaylist` | Every view model and view state: `HomeLibraryViewModel`, `SettingsViewModel`, `EpisodeEditView`, `EpisodeDetailsPane`, `TranscriptPane`, `AlbumDetailView`, `AlbumAnalysisView`, `TermDetailView` |
| `Importers` | `MatcherTests` (dead code, see P3 #2) | Spotify (dead) |
| `Extensions/Share` | none | `ShareInbox`, `YouTubeLinks` |
| `DemoData` | `DemoDataSeederTests` | — |

## Gap list against P0/P1 findings

Columns: the finding, whether a test exists that should have caught it, and the test to add. "None" means nothing touches the path. "Seam" means the code needs an injection point before a test is possible.

**01 DB**
- P0 #1 (v31/v32 run current-model code): `ScanDuplicateFoldTests.testFreshDatabaseMigratesInOrder` (`SameFileTests.swift:438`) should have caught it but migrates an empty DB, where v31/v32 loop over zero rows. → **T1**.
- P1 #2 (TrackMerge with 3+ copies): `SameFileTests.testFoldingDuplicatesAlreadyInTheLibraryKeepsWhatWasMarked` (`:195`) uses exactly two copies, so the stale-keeper overwrite never happens. → **T2**.
- P1 #3 (`saveEdit` lost update): `SameFileTests.testEditingAnEpisodeThatHasCopiesStillSaves` (`:178`) re-fetches right before saving, with no write in between. → **T6**: `TrackStoreTests.testSaveEditKeepsProgressWrittenAfterTheSheetOpened`. Set `t = find(a)`, then `recordProgress(a, 42_000)`, `setFavorite(a, true)`, `t.title = "x"`, `saveEdit(t)`. Assert `positionMs == 42_000`, `isFavorite`, `title == "x"`.
- P1 #4 (raw-copy undo snapshot): none, and `LocalBackups.copyDatabase` is static over the live DB, so this needs a seam. `LocalBackupsTests.testCopyDatabaseIsAConsistentSQLiteFile`: pass a file-backed queue in, copy while a `write` is open on another task, then open the copy and assert `PRAGMA integrity_check == "ok"`.

**02 Playback** (all 5 P1): none. `PlaybackEngineTests` covers only `nowPlayingArtwork`. The engine creates its own `AVQueuePlayer` and resolves URLs through the provider, so this needs a seam: inject a `PlayerDriving` protocol and a URL resolver.
- #1 `testALaterPlayWinsOverASlowerEarlierLoad`: resolver for A awaits a continuation, `play(A)`, `play(B)`, resume A. Assert the driver's last item is B.
- #2 `testAFailedLoadStopsTheOldAudioAndSavesNoProgress`: resolver throws for B. Assert `driver.isPaused` and B's `positionMs` unchanged.
- #3 `testAnInterruptionMarksPaused`: post `AVAudioSession.interruptionNotification` with `.began`. Assert `!isPlaying`.
- #4 `testExpiryRetryResumesFromThePlayhead`: `currentTime = 2400`, fail the item. Assert the retry seeks to 2400.
- #5 `testReplayingThePlayingEpisodeJustResumes`: `play(A)` twice. Assert one load.

**03 Providers**
- P1 #1 (Azure escaped path): `AzureBlobTests.testSharedKeySignsAListing` (`:13`) should have caught it but signs a container URL whose path needs no escaping. The SAS test (`:27`) shows the author knew about escaping but tested only the SAS. → **T5**.
- P1 #2 (`uploadEpisode` treats any HEAD failure as free): `EpisodeUploadTests.testAKeyTheListingDidntShowIsStillRefused` (`:130`) exists, but `WritableBucket.metadata` (`:25-28`) can only return the file or `missingFile`. → `EpisodeUploadTests.testAFailedExistenceCheckIsNotTreatedAsFree`: make `metadata` throw `URLError(.timedOut)`. Assert `send` throws and `writes.isEmpty`.
- P1 #3 (S3 drops empty segments): none. `S3RestClient.url` is private. → `SigV4Tests.testAKeyWithAnEmptySegmentKeepsIt`: expose `url(key:)` internally. Assert `url(key: "shows//ep.mp3").percentEncodedPath == "/shows//ep.mp3"` and that a trailing `/` survives.
- P1 #4 (dotted AWS bucket region detection): `BucketEndpointTests.testADottedAwsBucketGoesPathStyle` (`:17`) covers the endpoint but not detection. → `S3ProviderTests.testRegionDetectionUsesPathStyleForADottedBucket`: assert the detection URL for `my.podcasts` is `https://s3.amazonaws.com/my.podcasts`. This needs the URL builder split out of `detectRegion`.
- P1 #5 (GCS bucket force-unwrap): none. → `GoogleCloudStorageTests.testABucketNameWithASpaceThrowsRatherThanCrashing`: build the provider with bucket `"my bucket"` and call the URL builder. Assert it throws or produces an escaped path.

**04 Sync**
- P1 #1 (empty listing → everything lost): `SyncEngineTests.testSyncMarksRemovedFilesAsLost` (`:131`) covers this path and asserts the bug as the intended behaviour (P1 #1 below). → **T4**.
- P1 #2 (overlapping passes): none. `SyncQueueManager` is hard-wired to the app DB. → `SyncEngineTests.testACopyAddedAfterTheListingIsNotMarkedLost`: fake `listFiles` suspends on a continuation, insert a new `TrackFile` for `p`, then resume with the old listing. Assert the new copy has `isLost == false`.
- P1 #3 (failed jobs never retry, no network check): none. The test drain in `SyncEngineTests.swift:67-72` reimplements the loop and skips `fillTagReads` and failure handling (P2 #8). → after the seam, `SyncQueueManagerTests.testOfflineDrainClaimsNothing`: inject a monitor with `isConnected = false` and one pending `readTags` job. Assert it is still `pending` after `drain()`.

**05 Transcription**
- P1 #1 (`run` only when nothing stored): none. `TranscriptRunner` is a main-actor singleton with no injected store or engine. → `TranscriptRunnerTests.testRunOnAPartStoredTranscriptStartsAPass`: inject a fake transcriber, store one window, then `run(.onDevice)`. Assert the fake received a window after `stored.end`.
- P1 #2 (auto-retry on permanent failures): none. → `testAMissingKeyIsNotQueuedForResume`: fake throws `missingAPIKey`. Assert `interruptedEngine == nil`.
- P1 #3 (`isUploading` stuck): none. → `testSwitchingEpisodeMidUploadClearsUploading`: fake provider write suspends, `attach(B)`, then resume. Assert `!isUploading`.
- P1 #4 (upload writes the untagged file): `TranscriptLanguageTests.testUploadWritesTheLanguagesOwnFile` (`:50`) tests path naming only, not which language the runner passes. → `testUploadAfterAPassKeepsTheSidecarLanguage`: import `ep1.zh.vtt`, store one `onDevice` window, then upload. Assert the written path is `ep1.zh.vtt`.
- P1 #5 (merge across a silence marker no-ops): `TranscriptMergeSplitTests.testMergeDropsEmptyLinesRatherThanLeavingDoubleSpaces` (`:77`) should have caught it but passes the marker's own start, which the pane never does (P2 #2). → `testMergeAcrossASilenceMarkerJoinsTheTwoLines`: store `[(0,5,"a"), (5,6,""), (6,9,"b")]` and call `merge(starts: [0, 6])`. Assert `["a b"]`.
- P1 #6 (no-speech error ends the pass): none. → map-only test after the fix: `AppleSpeechTranscriberTests.testNoSpeechErrorIsAnEmptyResult`. Assert `AppleSpeechTranscriber.result(for: NSError(domain: "kAFAssistantErrorDomain", code: 1110))` is `.success([])`.

**06 AI**
- P1 #1 (300-token default): none. → `AiRouterTests.testLongFormPassesAskForEnoughTokens`: capture the request through a fake client. Assert `AlbumMetadataSuggester` for 12 episodes requests at least 12 × 80 `max_tokens`.
- P1 #2 (`ready[index]` recomputed at Apply): none, and the logic sits in a view. Extract `AlbumAnalysis.apply(suggestions:by id:)`, then test `testSuggestionsLandByEpisodeIDNotPosition`: the ready set changes between suggest and apply. Assert each title lands on its own id.
- P1 #3 (char budget vs model context): none. → `testKimiDefaultFitsAnOrdinarySummaryPrompt`: assert `EpisodeSummarizer.prompt(for: 40-min transcript).count / 3 < contextTokens(of: .moonshot default)`.
- P1 #4 (rejected default/preset models): `AiVendorStorefrontTests.testEveryCompatibleVendorHasAnEndpointAndDefaultModel` (`:25`) only checks the model id is non-empty (P3 #6). → `OpenAIChatClientTests.testReasoningModelsSendMaxCompletionTokens`: build the body for `o4-mini`. Assert `max_completion_tokens` is set and `max_tokens` is absent. Retired ids can only be caught by a live check.

**07 Library**
- P1 #1 (DuplicateTitles renumbers real "(n)"): `DuplicateTitlesTests.testALateArrivalJoinsAnExistingRun` (`:58`) asserts the bug's grouping as correct (P2 #3). → `testTagNumberedTitlesAreNotRenumbered`: `b.mp3 "Lecture (1)"`, `a.mp3 "Lecture (2)"`, both with `numberedFrom == nil`. Assert `renumbered(...)` is empty.

**08 Backup**
- P0 #1 (re-apply overwrites later edits): `CloudBackupTests.testReapplyingAfterASyncDoesNotReviveADeletedPlaylist` (`:70`) covers the right idea but only for playlists. `testApplyIsIdempotent` / `testRestoringTwice…` (`BackupServiceTests.swift:322`, `:174`) put no edit in between (P2 #1). → **T3**.
- P1 #2 (zip path traversal): none. → **T7**.
- P1 #3 (no rollback): none. → `BackupServiceTests.testAFailedApplyLeavesTheLibraryUntouched`: pre-insert an artist so the archive's second artist hits the unique index (or inject a throwing store). Assert the track count and titles equal the pre-apply values. `DatasetRestore` also needs a seam (its DB and `UserDefaults`) to test that `previousKey` is set before apply.
- P1 #4 (albums and speaker fields missing from the archive): `BackupServiceTests.testArchiveRoundTripsSnapshotAndSpeakerPhoto` (`:345`) covers only bio and photo. → `testAlbumAndSpeakerProfilesRoundTrip`: set album `notes`/`profile` and artist `knownFor`/`profile`, then `makeSnapshot` → `apply` onto a fresh DB. Assert all four come back.
- P1 #5 (swap wipes providers and AI keys): none. `DatasetRestore` is static over the live DB. After the seam, `DatasetRestoreTests.testRestoreOntoAnEmptyLibraryKeepsConnectedSources`: live DB with one provider and one `AiKey` and no tracks, then restore an archive. Assert both rows remain.
- P1 #6 (post-restore backup overwrites the archive): none. → after a `CloudDrive`/`AutoBackup` seam, `testRestoreDoesNotRewriteTheArchiveItCameFrom`: restore today's archive with `enableCloudDriveAfterRestore`. Assert no write to today's name.

**09 Importers**: no P0/P1. The dead-code tests are P3 #2 below.

**10 Player** (P0 #1, P1 #1–#5): the view state has no tests. The logic sits inside SwiftUI views (`EpisodeEditView`, `EpisodeDetailsPane`, `TranscriptPane`, `Bookmarks`).
- P0 #1 (sheet retargets): view identity, so it can only be caught by a UI test, or by checking that the fix uses `.sheet(item:)`. → UI test `EpisodeEditUITests.testEditSheetKeepsItsEpisodeAcrossAutoAdvance` with a 3 s demo episode.
- P1 #1 (language reverted on Save): the store half is testable now. `TrackStoreTests.testSaveEditDoesNotRevertLanguage`: `setLanguage(a, "zh")`, then `saveEdit(staleCopy)`. Assert the language is `"zh"`. T6 covers the same root cause.
- P1 #2 (✨ writes A's suggestion onto B) and P1 #3 (readiness for the previous episode): extract a `DetailsDraft` model, then test that a result arriving for a stale id is dropped.
- P1 #4 (orphaned editing state): extract the reset rule, then `testChangingTrackClearsEditingAndSelection`.
- P1 #5 (bookmark ‹ › on silence): `BookmarkStepperTests.testStepsSkipSilenceMarkers`: segments `[a, "", b]`, step from a. Assert it lands on b.

**11 Home** (P1 #1–#3): none.
- #1 `LibraryStoreTests.testOpeningAnAlbumDoesNotStampItEdited`: call the page's load path. Assert `metadataEditedAt == nil`. The save-on-open logic needs extracting first.
- #2 `TermStoreTests.testRecountKeepsATermThatIsStillMentioned`: `setTerms` then `recount`. Assert `episodes(forTerm:)` is non-empty.
- #3 `HomeLibraryViewModelTests.testAnOlderSearchCannotOverwriteANewerOne`: run search "ferr" with a delayed transcript fake, then "ferries". Assert the hits are for "ferries".

**12 Settings** (P1 #1–#3): none. `SettingsViewModel` talks to singletons.
- #1 `testImportIsRefusedInDemoMode`.
- #2 is a UI confirmation, so a UI test.
- #3 `AddCloudSourceModelTests.testCancelDuringValidationSavesNothing`: the fake `testConnection` suspends, then cancel and resume. Assert `ProviderStore.all().isEmpty`.

**13 App and CarPlay**
- P0 #1 (`assumeIsolated` on an off-main `libraryDidChange`): none. → **T8**.
- P0 #2 (Now Playing pushed twice): none. → extract `CarNavigation.next(stack:push:)` as pure logic, then `testNowPlayingIsPoppedToWhenAlreadyOnTheStack`: given `[tab, list, nowPlaying, list]` and a push of `nowPlaying`. Assert `.popTo(nowPlaying)`, and assert depth ≤ 5 after ten rounds.

**14 Build**
- P1 #1 (no privacy manifest): not a unit-test matter. → a `make check` step: `test -f Sources/App/PrivacyInfo.xcprivacy && plutil -lint`.

## Tests to add first (concrete)

**T1 — migration with data (01 P0 #1).** `Tests/MigrationUpgradeTests.swift`, `testAV30LibraryWithEpisodesMigratesToCurrent`.
- Setup:
  - `try Migrations.migrator().migrate(q, upTo: "v30_episode_summary_and_terms")`.
  - Raw-SQL `INSERT` a provider and three tracks: two sharing size and duration (so v32 folds them), each with a transcript, a `playlistTracks` row and a bookmark.
- Assert:
  - `XCTAssertNoThrow(try Migrations.migrator().migrate(q))`.
  - `trackFiles` count == `tracks` count.
  - `PRAGMA foreign_key_check` returns no rows.
  - The kept track has the duplicate's bookmark.
- Better still, also check in `Tests/Fixtures/v30.sqlite`, built by checking out `8f6109e^`, so later edits to v1–v30 can't hide the bug.

**T2 — TrackMerge with three copies (01 P1 #2).** `SameFileTests.testFoldingThreeCopiesKeepsEveryCopysMarks`.
- Setup: insert a, b and c with one fingerprint, as in `:197-205`. Mark only b: `isFavorite`, `notes = "keep"`, `listenedAt`. Give c `metadataEditedAt` so c is the keeper.
- Act: `foldDuplicates`.
- Assert: one row is left, and it has `isFavorite`, `notes == "keep"` and `listenedAt != nil`. Also run it through `foldAll` / `foldArrival` with a stale twin.

**T3 — restore apply and re-apply (08 P0 #1).** `CloudBackupTests.testReapplyAfterASyncKeepsEditsMadeSinceTheRestore`.
- Setup: the snapshot has ep1 (favourite, title "Old") and ep2, whose file was since deleted. `apply` it, then make local edits: rename ep1 to "New", unfavourite it, `setListened(false)`, delete its bookmark.
- Act: `apply(snapshot, scope: .needsSyncedTracks)`.
- Assert: title == "New", `!isFavorite`, `listenedAt == nil`, no bookmark.
- Second assert: `result.awaitingSync` stops counting ep2 once a full listing without it has completed. That is the 30-day loop.

**T4 — sync with an empty listing (04 P1 #1).** `SyncEngineTests.testAnEmptyListingDoesNotMarkALibraryLost`.
- Setup: sync two files, drain, then set `fakeFileLists[id] = []`.
- Act: sync again.
- Assert: `result.lost == 0`, nothing `isLost`, and the result reports that it held back.
- Rewrite the existing `:131` test to list two files and then one, asserting `lost == 1`.

**T5 — Azure escaped-path signature (03 P1 #1).** `AzureBlobTests.testSharedKeySignsAnEscapedBlobPath`.
- Setup: a `PUT` request to `https://myaccount.blob.core.windows.net/podcasts/shows/ep%201.vtt`, with `Content-Length: 5`, `Content-Type: text/vtt` and `x-ms-blob-type: BlockBlob`, signed at `moment`.
- Assert: `Authorization` equals a value computed outside this code: the Azure Python SDK, or CryptoKit HMAC-SHA256 in the test over a literal string-to-sign ending `/myaccount/podcasts/shows/ep%201.vtt`.
- Add a second case with non-ASCII (`节目 1.vtt`).

**T6 — `saveEdit` keeps other fields (01 P1 #3, 10 P1 #1).** See 01 above.

**T7 — zip path traversal (08 P1 #2).** `BackupServiceTests.testUnarchiveRefusesEntriesThatEscapeTheImageFolder`.
- Setup: build a zip with `ZipArchive` holding `snapshot.json` plus `artwork/../escape.txt` and `photos/../../escape.txt`.
- Act: `unarchive`.
- Assert: it throws, or no file exists at `ImageFileStore.artwork.directory.deletingLastPathComponent()/escape.txt`.
- Also assert that an archive with an unsupported `version` writes no images at all.
- Point the stores at a temp folder (P2 #5).

**T8 — CarPlay off-main notification (13 P0 #1).** Two tests:
- `SyncEngineTests.testLibraryDidChangeIsPostedOnMain` fails today, which proves the bug.
  - Setup: add a `NotificationCenter` observer (queue `nil`) that records `Thread.isMainThread` for `.libraryDidChange`.
  - Act: `await engine.sync(...)` and `drainQueue` with one file.
  - Assert: every recorded value is `true`.
- After the fix, extract the controller's merged publisher into `CarPlayController.refreshSignal(engine:)`. Then `testRefreshSignalDeliversOnMainForAnOffMainPost`: `Task.detached { post(.libraryDidChange) }`. Assert `Thread.isMainThread` inside the sink, with an expectation.

## P1

**1. `testSyncMarksRemovedFilesAsLost` asserts the empty-listing data-loss bug as correct.**
`SyncEngineTests.swift:131-149`
- The second pass sets the listing to `[]` and expects `result.lost == 1`. That is exactly 04 P1 #1 (a renamed local folder or a bad page marks the whole source lost).
- Any fix that refuses an empty listing fails this test. The likely response is to "fix" the fix, or to delete the guard.
- Fix: list two files, then one, and assert `lost == 1`. Add T4.

**2. Migrations are only ever tested from an empty database, so the upgrade crash for every pre-v32 install is invisible.**
`SameFileTests.swift:438-441` and every `makeDatabase()` helper (for example `BackupServiceTests.swift:6-10`)
- `testFreshDatabaseMigratesInOrder` is the only migration test. v31 and v32 loop over zero tracks, so neither the `needsTags` decode nor the `transcriptPaths` insert ever runs.
- Scenario: the next migration that touches models ships the same way, with the tests green.
- Fix: T1, and keep a fixture DB per shipped schema (one at least for the oldest TestFlight build).

## P2

**1. The "idempotent" restore tests only re-apply onto an unchanged library.**
`BackupServiceTests.swift:174-187`, `:322-340`; `CloudBackupTests.swift:45-66`
- They compare counts after two identical applies. No title, favourite, listened or bookmark change happens in between. `awaitingSync` is always 0, so the re-apply-until-expiry loop never starts.
- 08 P0 #1 passes every one of them. Fix: T3.

**2. The merge test hands the store the silence marker's start, which the UI never does.**
`TranscriptMergeSplitTests.swift:77-81`
- `starts: [0, 2, 4]` includes the empty line at 2. `TranscriptPane` builds its selection from `lines`, which drop markers, so in the app the call is `[0, 4]`. The store rejects that as non-contiguous (05 P1 #5).
- Fix: add the `[0, 6]` case from the gap list. Keep this one only if the store should also accept marker starts.

**3. A DuplicateTitles test treats tag-carried "(n)" titles as an app-made run.**
`DuplicateTitlesTests.swift:58-71`
- `"Talk (1)"` and `"Talk (2)"` have no `numberedFrom`, so they are the listener's or the publisher's numbers. The test still expects a bare `"Talk"` to join them as `(3)`. That is 07 P1 #1 scenario C, locked in.
- Fix: give the run `numberedFrom: "Talk"` here, and add the tag-numbered no-op test from the gap list.

**4. SigV4 has no known-answer signature, only structure and determinism.**
`SigV4Tests.swift:69-106`, `:110-140`
- The header comment promises checks "against AWS's own documented values". But the request tests assert the `Credential=` prefix, `contains("Signature=")`, equality with itself, and inequality with another secret. The presigned tests assert parameter names and that the URL changes.
- A wrong canonical URI (the Azure class of bug) or query order would pass. No key with a space, `//` or a trailing `/` is signed (03 P1 #3).
- Fix: add AWS's published `get-vanilla` / `get-vanilla-query-order-key` signatures and the S3 presign example (`examplebucket/test.txt`, `AKIAIOSFODNN7EXAMPLE`, expected `aeeed9bb…`). Add a key-with-space case.

**5. App-hosted tests write into the real app's folders and keychain.**
`project.yml:158-172` (hosted bundle); `BackupServiceTests.swift:349-356`; `ArtworkSidecarTests.swift:69-79`; `SyncEngineTests.swift:41-53`
- `ImageFileStore.speakerPhotos.save` and `BackupService.unarchive` write into the live photo and artwork folders. `ArtworkSidecar.adopt` writes into `ImageFileStore.artwork`, and its cleanup runs inline at `:79`, so a `try` failure above it leaves files behind. `ProviderManager.shared.saveSettings` writes keychain items. `CloudProviderRegistry.shared` gains a `test-fake` type for the life of the process.
- On the phone (the default target) these land in the user's own container. The host app's launch work (DB open, `AutoBackup`, observers) also runs during every test run.
- Fix: inject the image directory (`ImageFileStore(folderName:)` already exists, as `ImageFileStoreTests` shows) into `BackupService` / `ArtworkSidecar`. Use `addTeardownBlock` for cleanup. Consider `TEST_HOST`-less logic tests, or a launch argument that skips app start-up work under XCTest.

**6. `ChangeLog.mark` is global and the host app can move it mid-test.**
`LocalBackupsTests.swift:81-93`
- The test reads the mark, writes to an in-memory DB, and asserts the mark didn't move. Any write the host app makes to the live DB in that window moves it: launch maintenance, a sync started by `.active`, or progress saves. The result is a red test with nothing wrong.
- Fix: assert that `ChangeLog.record` was never called for this queue (inject a recorder). Or make the mark per-DB.

**7. The fakes can only succeed or say "not found", so the error paths behind three P1s can't be expressed.**
`EpisodeUploadTests.swift:25-28`; `SyncEngineTests.swift:12-21`; `CloudBackupFolderTests.swift:24-34`
- `metadata` either returns the file or throws `missingFile`, and `listFiles` never throws or returns a partial page. 03 P1 #2 (HEAD timeout counted as free) and 04 P1 #1 (short listing) need exactly those answers.
- Fix: give the shared fake a scripted `Result` per call (`.timeout`, `.forbidden`, `.partial([...])`), and move it to one file that every test uses.

**8. The sync tests replace the real drain loop, so the code with 04 P1 #3 in it is never run.**
`SyncEngineTests.swift:63-72`
- `drainQueue` dequeues and calls `perform` directly. `SyncQueueManager.drain` adds `fillTagReads`, failed-row exclusion, `pruneDone` and the posting, and none of that is covered. The comment says why: the manager is main-actor and hard-wired to the app DB.
- Fix: give `SyncQueueManager` an injected `DatabaseQueue`, provider factory and network monitor. Test the real `drain` (the offline test in the gap list).

## P3

**1. A placeholder test asserts nothing.** `EarToListenTests.swift:4-6` (`XCTAssertTrue(true)`). Delete it.

**2. The `TrackMatcher` tests cover dead code.** `MatcherTests.swift:1-64`. 09 P2 #1 found `TrackMatcher` and the Spotify importer unreachable. The only callers are these five tests, which keep the code alive. Delete them together with the code.

**3. A real run loop and the host's live window scene.** `KeyboardDismissalTests.swift:11-23`. It spins `RunLoop.main` for 0.5 s and makes a window key over the running app. On a slow or locked device the hosting controller may not attach in time. Wait on the condition instead (an `XCTNSPredicateExpectation` on `window.gestureRecognizers`).

**4. Midnight race.** `CloudBackupFolderTests.swift:49`. `BackupArchiveName.current()` is computed after the upload, from the real clock in the current time zone. A run that crosses midnight fails. Take the name from the upload, or inject the date.

**5. Random file sizes from `hashValue`.** `SameFileTests.swift:264`. `String.hashValue` is seeded per process, so `"a"` and `"b"` share a size 1 time in 65,536. They then share a fingerprint and fold, and `testNeglectingAnAlbumHidesItsEpisodesAndNewArrivals` (`:302`, count 2) fails at random. Use explicit sizes.

**6. The vendor default-model test only checks the id is non-empty.** `AiVendorStorefrontTests.swift:25-30`. This can't catch `gemini-1.5-flash` being retired or `o4-mini` rejecting `max_tokens` (06 P1 #4). Add the request-body test from the gap list. Keep a dated list of known-retired ids that the test refuses.
