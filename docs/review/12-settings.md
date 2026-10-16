# 12 Settings and remote screens (`Screens/Settings`, `Screens/Remote`)

Files read in full: all 14 under `Screens/Settings` (`SettingsViewModel`, `AddCloudSourceView`, `AddAiKeyView`, `AiKeyDetailView`, `AiKeysSettingsView`, `AiModelPicker`, `BackupSettingsView`, `BackupDocument`, `FlaggedItemsView`, `NeglectedItemsView`, `FixHistoryView`, `AboutSettingsView`, `SettingsSectionView`, `SettingsGroup`) and all 6 under `Screens/Remote` (`RemoteBrowserView`, `SourcesSectionView`, `SyncQueueView`, `FilePreviewSheet`, `RemoteFileGroup`, `README.md`). Also read, to confirm findings: `DemoData/DemoMode.swift`, `DemoData/DemoSecrets.swift`, `AppMode`, `DatasetRestore`, `LocalBackups.copyDatabase`, `AiKeyStore`, `AiKey` (vendor gating, `displayName`, `.custom` default model), `CredentialStore`, `ProviderManager.settings/bucketSettings/displayPath/rootFolder`, `BucketConnectionDraft.parse`, `describeCloudError`, the providers' `testConnection`, `S3Provider.listDirectory`, `BackupService.activeRemoteProvider`, `AutoBackup.enableForNewRemote`, `EpisodeUpload`, `TrackStore.deleteAll(forProvider:)`/`flagged()`, the `syncJobs` FK, `HomeView` Settings route.

Already covered elsewhere and not repeated: bucket-name validation and AWS region detection (03 #4, #5). `uploadEpisode` overwrite and requeue refusal (03 #2, 04). Flagged's overlapping detached loads and `RemoteBrowserView.loadStats` on main per notification (04 #9). The flagged "delete record" offer for lost episodes (04 #1). Snapshot, export and preview on main, archive memory, undo-restore without confirmation, stale backup info text (08 #8, #9, #14, P3). AI key test timeout, vendor error bodies, "transcribe on playback" copy (06). Spotify leftovers in `load()` (09). The player's unloaded `SettingsViewModel` for `RemoteBrowserView` (10). The two-transaction source delete (01).

**Checklist results:**
- Credential entry: key-pair secrets and AI keys use `SecureField`. Cloud fields are trimmed of whitespace and newlines before save. AI keys are trimmed of spaces only (P3). The GCS private key goes through a plain `TextEditor` (P3). No secret reaches an error or alert: every message is `localizedDescription` or a fixed string.
- Validation before save: both add sheets save only after a real request succeeds. But Cancel doesn't stop that request, so the save still happens (P1 #3).
- Connection test: only at add time. `SettingsViewModel.testConnection` has no caller, so an existing source can't be re-tested (P3).
- Destructive actions: the browser's Delete Connection and Flagged deletes are confirmed. The Sources row's long-press Delete isn't (P1 #2). Remove All App Data gives no progress and no result (P2 #10).
- Remote browser: `List`, so it's lazy. The listing is paged to the end before anything shows (P3). Re-grouping per row per render (P2 #4) and one DB read per episode on tap (P2 #5). Stack depth is unbounded but each level is cheap, apart from its notification observer (P3).
- Upload: the queue does the sending, so a big file never sits on this screen, and `mappedIfSafe` keeps it out of RAM where possible. There is no byte progress and no cancel from the browser (P3).
- Demo mode: the library is swapped through a stash, and backups, change log and first-run restore stand down. Import/undo restore isn't fenced off, and that leaks the sample library into the real one (P1 #1). The swap runs on main (P2 #1).
- China gating: clean. The add-key picker lists `AiVendor.offered`, the key list and count come from the filtered `AiKeyStore.all()`, and no AI vendor name is hard-coded in either folder.

Summary: credential handling is careful. Secrets go to the Keychain, nothing secret is echoed, and a save is always a real test. The serious problems are lifecycle ones. A restore made while in demo mode leaves an "Undo restore" behind that, after leaving demo, puts the sample library over the real one. A long-press deletes a source without asking. Cancelling an add sheet mid-test still adds the bucket or key. The rest is main-actor work (demo swap, source delete, keychain reads per keystroke, per-episode reads on tap), state that goes stale (AI key model, browser record), and a remote preview that garbles CJK transcripts. **P0 0 · P1 3 · P2 11 · P3 18**

## P1

**1. "Import Library Data" works in demo mode, and the undo it leaves behind puts the sample library over the real one.**
`BackupSettingsView.swift:94-143`; `SettingsViewModel.swift:334-357`; `DatasetRestore.swift:57-63`, `:94-103`; `LocalBackups.swift:76-87`; `AboutSettingsView.swift:32`
- Only Remove All is hidden in demo. Import calls `DatasetRestore.restore`, which copies `DatabaseManager.databaseURL` aside as "the library before the restore". In demo that file holds the sample library. It also sets `previousKey` in `UserDefaults`, which `DemoMode.leave()` doesn't touch.
- After leaving demo, Backup & Restore still offers "Undo restore — put back <date>" for a week. Tapping it (one tap, no confirmation, 08 #14) replaces the real library with the sample one. `AppMode.isDemo` is now false, so the next backups ship the sample library to iCloud and the bucket.
- The restore itself merged into the sample library, so it is thrown away on leave. Only `PendingRestore` survives, and it then re-applies into the real library after syncs.
- Scenario: a user tries demo mode, tests "Import" on a backup, leaves demo and later taps Undo, expecting to undo that import. Their library becomes the sample podcasts, and the daily backup overwrites today's archive with it. The real DB survives only as an unlisted `before-undo` file.
- Fix: hide Import and Undo restore while `AppMode.isDemo`, as Remove All already is. In `DemoMode.enter/leave`, clear `previousKey`/`previousAtKey` and `PendingRestore`, or store them per mode. Make `DatasetRestore.restore` refuse while in demo.

**2. Long-pressing a source and tapping Delete removes the connection with no confirmation.**
`SourcesSectionView.swift:87-93`; `SettingsViewModel.swift:183-203`
- The comment above says delete lives in the browser's menu because a delete next to the row is "too easy to hit by mistake". Yet the context menu calls `viewModel.delete(record)` directly. The browser's own Delete has a `confirmationDialog` (`RemoteBrowserView.swift:214-218`).
- What goes: the Keychain credentials (they have to be pasted again), the provider row and its queue jobs (cascade). Every episode with no other copy is orphaned and greyed out until the bucket is re-added and re-synced, and the bucket backup target changes.
- Scenario: a long-press on the row meant to open the preview, then a slip onto Delete. The 2,000-episode bucket disappears and every episode in the library turns "Audio missing".
- Fix: route the context menu through the same confirmation as the browser, or drop it. Say in the dialog what happens: "Episodes only in this bucket stay in your library as missing until you reconnect it. You'll need to enter the key again."

**3. Cancelling an add sheet while it tests still saves the connection or key.**
`AddCloudSourceView.swift:129-137`, `:283-326`; `AddAiKeyView.swift:82-88`, `:94-107`
- Save starts an unstructured `Task { await validateAndSave() }` / `save()`. Cancel stays enabled during the test and only calls `dismiss()`. The task isn't cancelled and checks nothing after the `await`. So when the test succeeds, `addCloudProvider` or `addAiKey` runs anyway.
- For a bucket, that also turns on bucket backup (`enableForNewRemote`), starts `FirstRunRestore.runAfterConnectingRemote`, and queues the whole bucket.
- Scenario: the user taps Save, sees the region detection spin, realises it's the wrong bucket and taps Cancel. A few seconds later the bucket appears under Sources and starts importing hundreds of files.
- Fix: keep the task in `@State` and cancel it in Cancel and `onDisappear`. After the test, `guard !Task.isCancelled else { return }` before saving. Or disable Cancel while `isValidating`/`isTesting`.

## P2

**1. The demo toggle copies, verifies and seeds whole databases on the main thread, with no confirmation.**
`SettingsSectionView.swift:80-90`; `DemoMode.swift:21-67`
- `enter()` checkpoints, backs up the live DB to a file, runs `PRAGMA quick_check` and two counts, then builds and seeds a new dataset. `leave()` does the reverse. All of it is synchronous inside `onChange`, which also stops playback and the scheduler.
- Scenario: a library of 5,000 episodes with transcripts (tens of MB). The switch freezes the UI for seconds, and a watchdog kill mid-`enter` leaves the flag set with the stash half-written.
- Fix: run the swap off main behind a progress state, and confirm first ("Your library is kept aside and comes back when you switch off").

**2. AI key detail saves the model past the view model: reopening shows the old model, every keystroke writes, and a custom key can be saved with no model.**
`AiKeyDetailView.swift:24-32`, `:46-50`, `:95-98`; `SettingsViewModel.swift:82-89`; `AiKey.swift:80`
- `modelBinding` calls `keyStore.setModel` with `try?`, not `viewModel.setAiKeyModel` (which has no caller). `viewModel.aiKeys` keeps the old `AiKey`, and `onAppear` seeds `model = key.model` from it.
- For `.custom` the model is a `TextField` that writes on every keystroke. Clearing it saves `nil`, and `.custom` has no default model (`""`).
- Scenario: pick a cheaper preset, go back, open the key again: it shows the old model while the DB calls the new one. On a custom server, select-all and retype the model name, and leave halfway. Every sync call now goes out with a partial or empty model and fails.
- Fix: go through `viewModel.setAiKeyModel`, pass the key by id and read it from `viewModel.aiKeys`, and save the custom field on submit or disappear. Refuse an empty model for `.custom`.

**3. The add-bucket form reads the Keychain twice per existing connection on every render, which means every keystroke.**
`AddCloudSourceView.swift:56-66`; `ProviderManager.swift:77-89`
- `displayPath(for:)` is called in `body`. It calls `bucketSettings` twice, and each is a `SecItemCopyMatching` plus a JSON decode. Every keystroke in any field re-renders `body`. `RemoteSourceRow` already caches the same call in `@State` on appear.
- Scenario: three S3 connections. Typing a 40-character secret makes about 240 Keychain reads on the main thread, and the field stutters on older phones.
- Fix: compute the paths once in `.onAppear`/`onChange(of: kind)` into `@State`.

**4. The browser regroups the whole listing several times per render, once more for each visible row, and re-renders on every queue tick.**
`RemoteBrowserView.swift:45`, `:66-75`, `:104`, `:316`, `:337-342`, `:355-368`
- `fileGroups` is a computed `RemoteFileGroup.group(files)`: `FileKind` per file, dictionary build, stem walks. `body` calls it twice for `scrollHandle`, then for the `ForEach`. `sidecarCaption` calls `showsMissingTranscripts` for each row with no sidecars, and that regroups everything again. `statsSummary` runs `FileKind` over all files too.
- `@ObservedObject queueManager = SyncQueueManager.shared` re-renders every pushed level whenever the queue publishes, which happens per job during a sync.
- Scenario: a folder of 2,000 files while a sync drains. Each queue update costs about 15 visible rows × a 2,000-file regroup, on every level of the stack. Scrolling stutters.
- Fix: group once in `load()`/`loadSynced()` into `@State var groups` and a `hasAnyTranscript` flag. Observe only `activeProviderIDs` (a derived publisher) rather than the whole manager.

**5. Tapping an episode reads the DB once per audio file in the folder, on the main thread, to build the play queue.**
`RemoteBrowserView.swift:501-504`
- `files.filter(isPlayable).compactMap { try? trackStore.find(...) }`. This is the per-item I/O loop CLAUDE.md forbids.
- Scenario: a 600-episode folder. Every tap does 600 queries before playback starts.
- Fix: one `TrackStore` query for `providerID == record.id AND filePath IN (...)` (or by path prefix), then order in memory.

**6. PLAUSIBLE: going back to a folder lists it again and shows a spinner, so scroll position is lost.**
`RemoteBrowserView.swift:85-95`, `:203`, `:386-388`
- `.task { await load() }` runs again when a pushed subfolder pops and the parent reappears. `load()` sets `isLoadingListing = true`, which replaces the whole section with a `ProgressView`.
- Scenario: scroll to the 300th folder, open it, go back. The list flashes to a spinner, a new paged listing goes out (20 requests for 20k keys), and you're back at the top.
- Fix: load once per level (`if files.isEmpty && folders.isEmpty`), and refresh in place with pull-to-refresh or after uploads, without blanking the list.

**7. "Auto sync app data to this bucket" appears under every active bucket, but it is one global switch, and backups go to the first writable bucket.**
`SourcesSectionView.swift:213-236`; `BackupService.swift:482-488`
- Each active bucket row shows a toggle bound to `autoBackup.isEnabled`, with the same "Last: …" hint. `activeRemoteProvider()` takes the first active writable cloud record in table order.
- Scenario: buckets A (old) and B (new). The user turns the toggle on under B to keep app data there. The archive goes to A. Turning it off under A also stops it "for" B.
- Fix: show the toggle once, naming the bucket it writes to, or store a chosen provider ID and use it in `activeRemoteProvider()`.

**8. Flagged selection survives a filter change, so a bulk fix acts on rows that aren't on screen.**
`FlaggedItemsView.swift:22`, `:49-53`, `:67-78`
- `selectedItems` filters `items`, not `shown`. Changing the filter doesn't touch `selection`.
- Scenario: filter "Audio missing", Select All (40), switch to "No title" to review, pick Delete record. The dialog says 40 episodes, and they are the 40 hidden lost ones, not what's listed.
- Fix: clear `selection` in `onChange(of: filter)`, or apply `selection ∩ shown`.

**9. The remote file preview garbles CJK text past 256 KB, and shows a whole file when the server ignores Range.**
`FilePreviewSheet.swift:61-90`
- The 256 KB cut lands mid-character in a multi-byte UTF-8 file. `String(data:encoding: .utf8)` then returns nil, and the `.isoLatin1` fallback renders mojibake.
- On a `200` reply, which a server sends when it ignores `Range`, the full body is kept (only the local branch takes a `prefix`). It is decoded in full and labelled "truncated" only if large.
- Scenario: a 2-hour Chinese `.vtt` (about 400 KB) previews as Latin-1 garbage.
- Fix: `data.prefix(maximumBytes)` on both branches. Before decoding, drop up to 3 trailing bytes until UTF-8 decodes, or decode lossily with `String(decoding:as: UTF8.self)`.

**10. Remove All App Data shows no progress and no result, and can be started twice.**
`AboutSettingsView.swift:33-47`; `SettingsViewModel.swift:252-289`
- The confirmation starts `Task { await removeAllAppData() }`, which first uploads a recovery archive to iCloud and the bucket. That can take a while. Nothing on the About page changes meanwhile. The result (`backupStatusMessage`, where the copy was saved) is only shown on the Backup page, and the error alert lives on `SettingsSectionView`, under the pushed page.
- Scenario: tap Remove Everything, see nothing happen, tap it again. Two runs race. The second's `backUpBeforeDeletion` can run after the first erase and write a recovery archive of the empty library.
- Fix: an `isRemoving` state that disables the button and shows progress. Show the result (and where the copy went) on this page, and guard re-entry in the view model.

**11. Deleting a source runs the whole re-homing on the main thread.**
`SettingsViewModel.swift:183-203`; `TrackStore.swift:267-289`; `RemoteBrowserView.swift:214-221`
- `deleteAll(forProvider:)` (per-track fetches, 01) and `numberDuplicateTitles()` (whole library) run synchronously from the button.
- With subfolders pushed, every level's `onChange` calls `dismiss()` together (PLAUSIBLE that only some levels pop).
- The dialog has no message about what happens.
- Scenario: deleting a 3,000-episode bucket freezes the UI for seconds, mid-dialog-dismiss.
- Fix: run both store calls detached, then `load()` on main. Pop to root once (`NavigationPath` reset) rather than per level. Add a message as in P1 #2.

## P3

- AI key and custom model aren't trimmed of newlines: `secret.trimmingCharacters(in: .whitespaces)` and an untrimmed `model`. PLAUSIBLE that a pasted key ending in `\n` survives a `SecureField` and fails as "invalid key". Use `.whitespacesAndNewlines`, as the cloud form does. `AddAiKeyView.swift:20`, `:101`, `:38`
- `canSave` checks the untrimmed bucket, so a bucket of spaces enables Save and tests an empty name. Trim in `canSave`. `AddCloudSourceView.swift:35`, `:288`
- The GCS service-account key, private key included, is typed or pasted into a plain `TextEditor`, and "Fill from an existing connection" writes it back on screen in clear. Show "Key loaded (client_email …)" and keep the JSON out of the view. `AddCloudSourceView.swift:168-170`, `:275`
- Adding a bucket while in demo mode calls `AutoBackup.enableForNewRemote()`. That persists to `UserDefaults` and switches bucket backup on for the real library after leaving. Skip in demo. `SettingsViewModel.swift:125`
- No way to re-test an existing source after its key is rotated or revoked. Errors only show as failed sync rows. Dead code that once did related things: `testConnection`/`testResults`, `toggleActive` (so a source can't be set Inactive from the UI, though rows show "Active"), `hasActiveRemoteProvider`, `setAiKeyModel`; in `RemoteBrowserView`, `syncNow`, `syncMessage`, `isSyncing` (never set true), `frequency`. Wire a "Test" item into the browser menu and delete the rest. `SettingsViewModel.swift:6`, `:29-31`, `:82-89`, `:205-226`; `RemoteBrowserView.swift:38-40`, `:434-447`
- The browser's `record` is `@State` copied at push, so "Last synced" in the menu never updates after a sync, and subfolders get the stale copy. Read it from `viewModel.providers` by id. `RemoteBrowserView.swift:20`, `:176`
- `highlight` is documented as "scroll to and mark on arrival", but nothing scrolls. In a long folder the tinted row may be off screen. `proxy.scrollTo(highlight)` after load. `RemoteBrowserView.swift:49-51`, `:258`, `:284`
- `listDirectory` follows every continuation token before returning, so a 20k-key folder shows a spinner through 20 sequential requests. Stream pages into the list. `S3Provider.swift:99-123`
- Upload: one bookmark plus one DB write per picked file on main. No byte progress, and no cancel for an in-flight upload except "Remove all" in the queue. `uploadMessage` never clears. Batch the enqueue into one transaction, and show the job's stage and progress in the footer. `RemoteBrowserView.swift:470-482`; `EpisodeUpload.swift:51-70`
- `play` swallows the import error ("Couldn't load that file."), and its task outlives the page. Leaving during a slow import starts playback later from nowhere. Surface `describeCloudError`, and cancel on disappear. `RemoteBrowserView.swift:484-505`
- Each pushed browser level observes `libraryDidChange` → `loadStats`, which multiplies 04 #9's scan by stack depth. `rootFolder` is another Keychain read per call. Cache the root folder and only refresh the top level. `RemoteBrowserView.swift:205`, `:428-432`
- The preview renders up to 256 KB in one `Text` (not lazy), and the local branch reads the whole file before `prefix`. Split into lines in a `LazyVStack`, and read with a `FileHandle`. `FilePreviewSheet.swift:27-33`, `:80`
- A Flagged destructive fix where no selected item applies opens "Delete record — 0 episodes?" and runs on nothing. Disable it when the filtered target list is empty. The rename title is saved untrimmed. `FlaggedItemsView.swift:180`, `:224`
- Neglected "Bring Back" records a fix-history entry even when `restore()` threw. Fix history's Clear has no confirmation. `NeglectedItemsView.swift:48-52`; `FixHistoryView.swift:30`
- Deleting an AI key is one menu tap with no confirmation, and the Keychain delete is `try?`. Confirm, since re-adding needs the vendor console. `AiKeysSettingsView.swift:52-57`; `AiKeyStore.swift:42-45`
- PLAUSIBLE: `AiModelPicker.onAppear` decides "custom" from `model`, which the parent only seeds in its own `onAppear`. If the child's fires first, a saved custom model shows as "Default". Seed the parent's state in `init`. `AiModelPicker.swift:44-48`; `AiKeyDetailView.swift:95-98`
- Settings `onAppear` runs `load()` on every return to the page: two Keychain reads, the AI-key legacy check, and a whole-library `flagged()` scan. The frequency setter swallows its write error. Load flagged on a debounce of `libraryDidChange` instead. `HomeView.swift:125`; `SettingsViewModel.swift:33-55`; `SourcesSectionView.swift:245`
- Doc and copy drift. The Remote README says "Browsing doesn't" touch the network (the listing is live) and names `EpisodeUpload.run` (it is `queue`). The import dialog says "It becomes your library", but onto a living library it merges (same issue as 08's info-row P3). `README.md:22-24`, `:162`; `BackupSettingsView.swift:43`, `:50`

## Tests to add

- Demo enter → import archive → leave: `DatasetRestore.previousLibrary` is nil, or undo leaves the real library intact (P1 #1).
- `AddCloudSourceView`/`AddAiKeyView`: a cancelled save doesn't call `addCloudProvider`/`addAiKey` (P1 #3). This needs the save logic pulled into a testable model.
- `RemoteFileGroup.group` on 2,000 files is computed once per listing (P2 #4). The play queue for N files is one query (P2 #5).
- `FilePreviewSheet` decoding a CJK buffer cut at an arbitrary byte gives valid UTF-8 text, not Latin-1 (P2 #9).
- Flagged: a filter change clears the selection (P2 #8).
- AI key model change through the detail page is reflected in `SettingsViewModel.aiKeys`, and `.custom` refuses an empty model (P2 #2).
