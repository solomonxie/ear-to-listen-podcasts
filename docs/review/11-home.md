# 11 Home, playlists and terms screens (`Screens/Home`, `Screens/Playlists`, `Screens/Terms`)

Files read in full: all 19 under `Screens/Home` (`HomeView`, `HomeLibraryViewModel`, `LibrarySearch`, `HomeRoute`, `AlbumDetailView`, `AlbumAnalysisView`, `SpeakerDetailView`, `BookmarksSection`, `BookmarkInsightsView`, `ListenHistorySection`, `ContinuePlayButton`, `EpisodeListView`, `TrackRow`, `SpeakerAvatar`, `SpokenLanguagePicker`, `ProfileSuggestionState`, `RemovalDialogs`, `AddYouTubeEpisodeView`, `WelcomeCard`), all 5 under `Screens/Playlists` and all 3 under `Screens/Terms`. Also read, to confirm findings: `ContentView` (how Home is mounted, `PlaybackEngine` observation), `ShowMoreList`, `TranscriptSearch`, `PlaylistStore`, the `playlistTracks` table in `Migrations.swift`, `LibraryStore.updateAlbum`/`updateArtist`/`recentAlbums`/`setTopics`/`reassignAlbumArtist`, `TermStore.topTerms`/`recount`/`episodes(forTerm:)`, `TrackStore.all`/`listenLater`/`youTubeEpisodes`/`tracks(forArtist:)`, `ArtworkSidecar` album adoption, `ChangeLog.record`, `AutoBackup` observer, `EpisodeRemoval`, `AlbumMetadataSuggester.partition`, `Tests/LibrarySearchTests.swift`.

Already covered elsewhere and not repeated: the `AlbumAnalysisView` apply-index race and `partition` decoding on main per body (06). `TranscriptSearch` matching raw JSON and its ranking (01 #10). `FixedPlaylistView` reloading per `libraryDidChange` with no debounce (04). `FixedPlaylistView`'s per-track `cachedSize` (02 #9). `TrackRow`'s `EpisodeEditView` sheet retargeting is not the 10 P0 shape: the row is keyed by `track.id`, so the sheet stays on the same episode.

**Library search, against the step-07 checklist:**
- Fold once: yes. `LibrarySearch.index` folds in `HomeLibraryViewModel`'s detached snapshot, not per keystroke.
- Off main: yes. The in-memory scan and the transcript scan both run in `Task.detached`.
- Stale queries: **no.** See P1 #3 and P2 #3–#5.
- Folding: case only. No diacritic, width or script folding (P2 #1).
- Ranking: none. Results come back in table order, and the 200 cap can drop the exact title match (P2 #2).
- Lazy results: yes. Each result section is a `LazyVStack` inside the page's `LazyVStack`, and episodes are capped at 200.

**Index-based `ForEach`: clean.** Every list is keyed by a stable ID. `BookmarkGroupRow` and `TermsPageView` enumerate with `id: \.element.id` and only use the index for a label or a highlight. `FixedPlaylistView`'s `onDelete` offsets index the same `entries` the list draws.

**Lazy lists: mostly fine.** Album, speaker, playlist, term and fixed-playlist pages are `List`s, and Listen History is a `LazyVStack`. The exceptions are Home's horizontal shelves (P2 #8).

Summary: search does the expensive parts right. It folds once, scans off-main and lays results out lazily. But it never checks whether the query it answered is still the one on screen. It doesn't re-run when the library under it changes. It shows "No Results" while the transcript scan, which is the app's core feature, is still running. It folds only case. Outside search, the worst bug is the album page's auto-save. Merely opening an album with a speaker writes the row and stamps it as hand-edited. That reorders Home and stops folder covers from ever being adopted. The term page can go blank under the reader because of its own recount. Playlists can be created but never deleted, renamed, reordered or emptied from their page. **P0 0 · P1 3 · P2 18 · P3 16**

## P1

**1. Opening an album page saves it, which stamps it as hand-edited.**
`AlbumDetailView.swift:229-230`, `:366-375`, `:381-405`; `LibraryStore.swift:157-171`, `:193-206`; `ArtworkSidecar.swift:128-131`
- `load()` ends in `seedFields()`. That sets `speakerName` from `""` to the album's speaker and `language` from `nil` to the stored value. Both have `.onChange { save() }`, so the first load of any album with a speaker or a language calls `save()`. Nothing was typed.
- `save()` calls `updateAlbum`, which always sets `metadataEditedAt = Date()`. It also runs `updateAlbumLanguage`, rewrites the topic links with `setTopics`, and posts `libraryDidChange`, so Home and this page fully reload.
- Effects:
  - `recentAlbums` orders by `MAX(played, metadataEditedAt)`, so every album you merely look at jumps to the front of Home's Albums shelf. "Recently played from or edited" becomes "recently opened".
  - The Stats section says "Edited <now>".
  - `ArtworkSidecar` adopts a folder's `cover.jpg` only when `metadataEditedAt == nil`. An album you once opened never picks up its cover from the bucket.
- The same unconditional `save()` runs on every blur of every field (`:225-228`), even when nothing changed.
- Scenario: browse five albums from a speaker's page to find one. Home's Albums shelf now leads with those five, all marked edited. A `cover.jpg` added to their folders later is ignored.
- Fix: keep a snapshot of the seeded values. In `save()`, return early when nothing differs from the snapshot, and stamp `metadataEditedAt` only for the fields the user changed. Alternatively, set a `isSeeding` flag around `seedFields()` and ignore `onChange` while it is set.

**2. A term page opened from Home goes blank while you read it, and its own recount is what triggers it.**
`HomeView.swift:110-113`; `TermDetailView.swift:55-58`, `:188-205`; `TermStore.swift:162-171`
- `.term(id)` resolves through `homeData.terms`, which is `topTerms(limit: 40)`. On open, `TermDetailView.healCounts()` recounts every listed episode against its transcript. If anything changed, it posts `libraryDidChange`. Home refreshes, `destination` is re-evaluated, and if the term has dropped out of the top 40 the `if let` yields nothing. The pushed page becomes empty.
- Healing lowers counts that the AI pass over-guessed, so the terms near the bottom of the 40 are exactly the ones that fall out. Any transcription pass finishing elsewhere can do the same.
- Scenario: open the 38th term from Terms → More. A second later the list disappears, leaving a blank page with a title bar.
- Fix: resolve the route from the database (`TermStore.find(id:)`), not from Home's top-40 array. Or carry the `Term` in the route (`case term(Term)`, which is `Hashable`) and let `TermDetailView` load its own rows.

**3. Superseded searches still write their results, so transcript hits from an older query can sit under a newer one.**
`HomeView.swift:56-66`; `HomeLibraryViewModel.swift:160-165`; `TranscriptSearch.swift:43-65`
- `.task(id: query)` cancels the old task, but both scans are `Task.detached`. Detached tasks don't inherit cancellation, so `await` returns normally. Neither assignment (`results =`, `transcriptMatches =`) checks `Task.isCancelled` or whether `query` still matches.
- Reads on the `DatabaseQueue` are serial, but `matches(for:)` decodes and filters up to 30 transcripts *after* its read. A shorter, broader query (task A) can finish decoding after a longer, narrower one (task B) has already landed. A's `transcriptMatches` then replaces B's and stays.
- Clearing the field resets both arrays, but an in-flight task lands afterwards. The next search then shows the old transcript rows until its own scan returns.
- Scenario: type "ferr", pause, then type "ies at dawn". "In transcripts" shows the lines for "ferr", under episode and note results for "ferries at dawn". Tapping a row plays a moment that doesn't contain the query.
- Fix: after each `await`, `guard !Task.isCancelled, query == searched else { return }`. Better, make one detached task that returns both halves together with the query it answered, and assign only if that is still the current query.

## P2

**1. Search folds only case: no diacritic, width or script folding.**
`LibrarySearch.swift:54`, `:95`; `TranscriptSearch.swift:41-45`
- `fold` is `lowercased()`. "cafe" doesn't find "Café". "Zoe" doesn't find "Zoë". Full-width "ＡＩ", which Chinese keyboards produce in full-width mode, doesn't find "AI".
- Simplified and traditional Chinese (讲/講) don't meet. Neither do kana variants.
- The transcript half needs at least 2 characters (`minimumQueryLength`), so a meaningful single-character CJK query (爱, 禅) finds nothing in speech.
- Scenario: a listener with a Chinese keyboard left in full-width mode searches "ＧＰＴ" and gets "No Results" for a library full of GPT episodes.
- Fix: `fold` = `text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)`, applied at index time and to the needle. Optionally add `applyingTransform(.init("Hant-Hans"), reverse: false)`. Measure the length gate in UTF-8 bytes or exempt CJK, so one Han character passes. Mirror this in `TranscriptSearch`, where SQL `lower()` can't fold. That means filtering in Swift or storing a folded column, which is 01 #10's fix.

**2. No ranking, and the 200-episode cap can drop the best match.**
`LibrarySearch.swift:98-111`; `TrackStore.swift:345-347`
- `matches` filters in index order. Tracks come from `all()` with no `ORDER BY`, so in practice rowid order. A title match, a path match, a notes match and a year match all rank the same. With `prefix(episodeLimit)`, an episode whose *title* is the query can sit at position 350 behind 200 files whose folder path contains it.
- The same applies to speakers (bio hits rank the same as name hits) and notes.
- Scenario: search "2023" in a bucket sorted into `2023/…` folders. The header reads "first 200 of 640". The episode titled "2023 in review" isn't among the 200.
- Fix: keep the fields separate in the index (`title`, `rest`) and score each hit: exact title, then title prefix or word start, then title substring, then other fields, with recency as a tiebreak. Sort by score, *then* apply `prefix`. It stays O(n) plus a sort of the hits, off-main.

**3. Results don't re-run when the library changes, including the empty index at launch.**
`HomeView.swift:56-64`; `HomeLibraryViewModel.swift:29`, `:73`
- The task is keyed only on `query`. A search typed before the first `refresh()` lands runs against an empty `Index()` and shows "No Results" until the next keystroke. A search left open while a sync imports, or after an episode is deleted from a result's context menu, keeps showing the old rows. Tapping one calls `PlaybackEngine.open` with a `Track` copy that may no longer exist.
- Scenario: launch, tap the search bar at once and type a name. Nothing is found, although the episode is there. Typing one more letter finds it.
- Fix: give the index a revision counter (bump it in `refresh()`) and key the task on `"\(query)|\(homeData.searchRevision)"`.

**4. "No Results" shows while the transcript scan is still running.**
`HomeView.swift:292-294`
- There is no in-flight state. For the 180 ms debounce, and then for the whole transcript scan, `results.isEmpty && transcriptMatches.isEmpty` holds, so the page shows `ContentUnavailableView.search`. A query that matches only speech (the app's headline feature) says "No Results" first and changes its answer seconds later on a large library.
- Scenario: search for a phrase you remember hearing. The screen says no results, so you change the query, which cancels the scan that would have found it.
- Fix: keep `@State var isSearching`, set before the sleep and cleared when the transcript half lands. Show a small progress row instead of the empty state while it is set.

**5. Transcript scans can't be cancelled, so a slow typist queues full-table scans on the serial database.**
`HomeView.swift:62-65`; `HomeLibraryViewModel.swift:160-165`
- Each pause over 180 ms launches a detached `instr(lower(segmentsJSON))` over every transcript. Cancelling the `.task` doesn't stop it. A CJK IME also fires these on pinyin while it composes. The scans serialize on the `DatabaseQueue` and block every other read and write behind them. That includes the main-thread reads on album pages (#10) and the player's periodic position write (01).
- Scenario: type a 10-character query slowly on a library with 2,000 transcripts. Up to 10 full scans run back to back, and the album page's fields lag while they do.
- Fix: run the scan inside a child task (not detached), or check `Task.isCancelled` between candidate rows. Use GRDB's `db.interrupt` / `DatabasePool` reads for the long statement. Raise the debounce for the transcript half, for example 350 ms, separately from the in-memory half.

**6. Home re-reads the whole library every time you come back to it.**
`HomeView.swift:67`; `HomeLibraryViewModel.swift:48-75`
- `.task { await homeData.refresh() }` is on the stack's root view. A root view gets `onDisappear`/`onAppear` when a page is pushed and popped, so the task restarts on every back navigation. Each run re-reads about 13 queries (all tracks, all bookmarks), rebuilds the bookmark groups and re-folds the whole search index. The `libraryDidChange` observer already keeps it current.
- Scenario: browsing album → back → album → back on a 5,000-episode library runs a full snapshot and fold per pop, competing with the album page's own load.
- Fix: `.task { if !homeData.hasLoaded { await homeData.refresh() } }`, and rely on the notifications for everything after that.

**7. PLAUSIBLE: the "refresh when the player closes" hook doesn't fire when the player closes.**
`HomeView.swift:74-76`; `ContentView.swift:4`, `:59-61`
- `HomeView` reads `PlaybackEngine.shared.isPresentingPlayer` without observing the engine (it is an `ObservableObject`, not `@Observable`). `onChange` only compares when Home's body runs, and Home has no inputs from `ContentView`, so SwiftUI can skip its body when the player toggles. The refresh then fires at Home's next unrelated redraw, if at all. Continue Listening, Listen History and "Recently played" albums depend on it, because playing posts no `libraryDidChange`.
- Scenario: listen to an episode, close the player, and Continue Listening still shows yesterday's order and progress.
- Fix: observe `PlaybackEngine.shared` in a tiny modifier view, or have `ContentView`'s existing `.onChange(of: engine.isPresentingPlayer)` post a notification that Home handles with `refreshSoon()`.

**8. Home's horizontal shelves are eager and unbounded.**
`HomeView.swift:174-183`, `:241-250`, `:270-279`, `:435-439`; `SpeakerAvatar.swift:22-57`
- `shelf` is an `HStack` in a horizontal `ScrollView`. The Speakers shelf holds every non-neglected speaker, and Topics and Years hold every topic and year. Each `SpeakerAvatar` builds a gradient and a `Canvas` motif and starts a `.task` that reads and decodes its photo from disk. All of them are built when Home appears, not when they are scrolled to.
- Scenario: a library with 400 speakers builds 400 canvases and starts 400 file decodes at launch, before the user scrolls the shelf.
- Fix: `LazyHStack` in `shelf`, and cap the Speakers and Topics shelves (as Terms does with `prefix(24)`) with a "More" link.

**9. The speaker page writes on open and on every blur, which logs changes and triggers auto-backup.**
`SpeakerDetailView.swift:208-212`, `:251-260`, `:262-278`; `LibraryStore.swift:43-71`; `ChangeLog.swift:46-55`; `AutoBackup.swift:70`
- This is the same shape as P1 #1. `seedFields` sets `language` from `nil` to the stored value, `.onChange(of: language)` calls `save()`, and `save()` calls `updateArtist` with every field. `updateArtist` always writes a `ChangeLog` entry, which posts `backedUpDataDidChange`, which `AutoBackup` observes. Any blur saves again with no dirty check.
- Scenario: open a speaker whose language is set, and scroll past their fields. The change log gains entries with identical old and new values, and auto-backup is scheduled for edits nobody made.
- Fix: as P1 #1, compare with the seeded snapshot and skip unchanged saves. In `updateArtist`, skip the write and the log when old equals new.

**10. The album page does several DB reads per body pass, and the body runs on every keystroke.**
`AlbumDetailView.swift:86-87`, `:322-336`, `:343-363`; `SpokenLanguagePicker.swift:25-41`
- `speaker` is a computed property doing `libraryStore.artist(id:)` on main. The body reads it through `hidesChevron`, `speakerAccessory`, `speakerLanguageLabel` and `artworkSubject` (three times there), which is about six reads per pass. Typing in Name, Notes or Profile re-runs the body per character.
- `SpokenLanguagePicker.options` rebuilds and sorts the recogniser locale list and names each locale on every pass. `shown.get` builds it a second time.
- Scenario: type a paragraph into Profile while a sync or a transcript scan (#5) holds the database. Each keystroke waits on several serialized reads.
- Fix: load the speaker in `read(albumID:)` with the rest and keep it in `@State`. Make the language options a `static let`.

**11. Three pages still read the database on the main actor.**
- `SpeakerDetailView.load()` reads the speaker, albums, every track and all their bookmarks on main. `AlbumDetailView` moved off main for this reason. The page also has no `libraryDidChange` observer, so renames and new episodes don't show until it is reopened. `SpeakerDetailView.swift:229`, `:364-370`
- `TermDetailView.load()` runs one `album(id:)` and one `artist(id:)` query per distinct album and speaker in a loop on main. That is per-item I/O. `toggle` claims to be "off the main actor", but `transcriptStore.find(trackID:)` decodes the whole transcript in a main-actor `Task`. Only the mention scan is detached. `TermDetailView.swift:162-170`, `:207-217`
- `BookmarksView.load()` reads every track in the library and every bookmark on main, on appear and on each `bookmarksDidChange`, just to group. `BookmarksSection.swift:125-133`
- Fix: one `Task.detached` read per page that returns a `Sendable` struct, as `AlbumDetailView.read` does. For terms, read names with `Album.filter(keys:)`/`Artist.filter(keys:)` in one query each. Detach the transcript decode in `toggle`. Debounce `libraryDidChange` on the speaker page with the album page's `loadSoon`.

**12. PLAUSIBLE: view-destination `NavigationLink`s inside sections that rebuild can pop the page they opened.**
`BookmarksSection.swift:30-35`, `:55-58`; `AlbumDetailView.swift:168-175`; `SpeakerDetailView.swift:81-85`
- `HomeRoute` exists because a link rebuilt underneath an open page misbehaves (see its doc comment). These links still use `NavigationLink { View() }`.
- "See all" on Home's Bookmarks shelf only exists while `groups.count > 4`. Deleting marks from the pushed `BookmarksView` posts `bookmarksDidChange`, Home regroups, and if that drops to 4 or fewer groups (or to none, which removes the section), the active link leaves the hierarchy and SwiftUI pops the page.
- The album page's term chips are rebuilt when `TermDetailView.healCounts` posts `libraryDidChange` while the term page is open.
- Scenario: with marks in five episodes, open "See all" and delete one episode's marks. The page closes under your finger.
- Fix: push these through `HomeRoute` too (`.bookmarks`, `.term`, `.album`) with `NavigationLink(value:)`.

**13. Playlists can be created but not deleted, renamed, reordered or emptied from their page.**
`PlaylistDetailView.swift:10-44`; `PlaylistStore.swift:12-31`
- `PlaylistStore.rename` and `delete` have no caller. `PlaylistDetailView` has no `onDelete`, no `onMove`, no edit mode and no menu. The only way to take an episode out is to find it again through + → category → toggle. A playlist created by a mistyped name stays on Home for good.
- The page also doesn't observe `libraryDidChange`, and `tracks(inPlaylist:)` doesn't filter neglected tracks, so a neglected episode stays listed and playable here only.
- Fix: add `.onDelete` (call `removeTrack`), `.onMove` (rewrite positions in one transaction), and a toolbar menu with Rename and Delete Playlist that pops on delete. Filter `neglectedAt IS NULL` in `tracks(inPlaylist:)`.

**14. Playlist positions collide after a removal, so the order becomes arbitrary.**
`AddToPlaylistSheet.swift:77-80`; `AddTracksToPlaylistView.swift:115-117`; `PlaylistStore.swift:37-45`, `:77-86`
- New tracks go in at `position = current count`. Positions are never compacted on removal. With [a:0, b:1, c:2], removing b and adding d puts d at 2, tied with c. `ORDER BY playlistTracks.position` has no tiebreak, so c and d can swap between reads. Each of these reads also costs a full playlist fetch just to count it.
- Re-adding a track that is already in the playlist `save()`s over its row with the new position, which silently moves it to the end.
- Fix: insert at `COALESCE(MAX(position), -1) + 1` in SQL inside `addTrack`, and order by `position, rowid`. Skip (or report) a track that is already present.

**15. The "All" terms page lists only the top 40, so the remaining terms can't be reached from Home.**
`TermsSection.swift:3`, `:55`; `HomeView.swift:126-127`; `TermStore.swift:162`
- `TermsPageView(terms: homeData.terms)` receives `topTerms(limit: 40)`. The doc says "Every term the library holds" and the section header says "All 40". A term ranked 41st has no page reachable from Home or search, because terms aren't in `LibrarySearch.Index` either.
- Fix: have the page load `topTerms(limit: .max)` itself (detached), and add terms to the search index.

**16. Deleting or neglecting an album or speaker leaves its episode playing.**
`RemovalDialogs.swift:109-115`
- `finish()` unloads the engine only for `.episode`. After deleting an album whose episode is playing, the player keeps playing a deleted row from cache, Up Next still holds the album's other deleted tracks, and position writes target rows that are gone.
- Fix: unload when `currentTrack` belongs to the removed album or speaker (`albumID`/`artistID` match), and drop removed IDs from the queue.

**17. The language picker shows "English" when nothing is set.**
`SpokenLanguagePicker.swift:34-41`; `SpeakerDetailView.swift:107-110`; `AlbumDetailView.swift:360-363`
- When `language` is nil, the wheel selects the option whose label equals `inheritedLabel`. The speaker page passes `"automatic"`, and the album page passes it when the speaker has no language. No option is labelled "automatic", so the fallback `options.first` (English, by `ordered`) shows as the selection. The page claims the speaker is set to English when recognition is automatic.
- Explicitly choosing English is then a no-op, because the wheel is already on it, so `language` stays nil.
- Scenario: a Chinese speaker's page shows Language: English. The user, trusting it, blames the recogniser.
- Fix: add an "Automatic" option (`value: nil`) at the top, and show it when there is no inherited language.

**18. Changing the link in Add YouTube Video keeps the previous video's title and channel.**
`AddYouTubeEpisodeView.swift:110-126`
- `lookUp` fills `title` and `speaker` only when they are empty. Edit or paste a different link and `.task(id: videoID)` re-runs, but the fields still hold video A's title, so B is saved under A's title and channel.
- Fix: remember what the lookup wrote (`autoTitle`, `autoSpeaker`), and on a new `videoID`, replace a field whose value still equals the auto value.

## P3

- A note typed or edited from Home (the editor posts `bookmarksDidChange`) updates the shelf but not `searchIndex`. The note isn't searchable until the next library refresh. Rebuild the `notes` part of the index in `refreshBookmarks`. `HomeLibraryViewModel.swift:199-206`
- `homeData.track(id:)` is a linear scan of every track. It runs per visible Notes row and transcript-hit row, per body pass, and on every tap. Keep a `[String: Track]` in the snapshot. `HomeLibraryViewModel.swift:197`; `HomeView.swift:333`, `:347`, `:361-369`
- Notes and transcript hits for neglected episodes show with no episode title, and tapping them does nothing (`guard let track … else { return }`). Filter them out of the index and the transcript results, or say why. `HomeView.swift:361-369`
- A whitespace-only query switches Home into search mode and shows "No Results for '  '". Use `query.trimmingCharacters(in: .whitespaces).isEmpty` for the branch. `HomeView.swift:27`, `:57`
- PLAUSIBLE: `refresh()` has no generation guard. `.task`, the player-close hook, `createPlaylist` and `refreshSoon` can overlap (cancelling `refreshSoon` only stops a sleeping task), and an older snapshot can land last. Stamp each run and drop results older than the newest. `HomeLibraryViewModel.swift:48-75`, `:170-183`
- On first launch, `showFirstShelves` fills `recentAlbums` but not `albums`. Tapping an album card before the full refresh lands pushes `.album(id)`, which resolves to an empty page until it does. On an empty library, every refresh also re-runs the first-shelves queries. `HomeLibraryViewModel.swift:49`, `:80-94`; `HomeView.swift:95-97`
- The Bookmarks header counts only `bookmarkStore.recent()` (30 marks): "See all 30" on a library with 300. Count with `SELECT COUNT(*)`. `BookmarksSection.swift:23`, `:34`, `:37`
- Topic names are stored and seeded as one comma-joined string and split on `,` at save. With P1 #1's auto-save, a topic like "Faith, Hope" is split into two just by opening the album. Keep `[String]` in state. `AlbumDetailView.swift:99-101`, `:373`, `:392`
- PLAUSIBLE: `handleArtworkPick` and `removeArtwork` don't refresh `current`. A blur inside the reload window makes `save()` write the old `artworkFileName` back, and that file was just deleted. Refresh `current` as `saveArtwork` does. `AlbumDetailView.swift:475-487`, `:507-514`, `:387`
- Fixed playlists:
  - `removeDownloads` doesn't post `libraryDidChange`, so Home's Downloaded count stays stale.
  - `youTubeEpisodes()` includes neglected videos while the Home count (`youTubeCount`, from shown tracks) excludes them.
  - `FixedPlaylistView.swift:136-146`, `:98-99`; `TrackStore.swift:820-826`
- `AddToPlaylistSheet` posts nothing after creating a playlist or adding to one, so Home's shelf doesn't show the new playlist until some unrelated refresh. `isQueued` runs a DB read in `body`, twice. `AddToPlaylistSheet.swift:18-20`, `:31-37`, `:77-81`
- The speaker page opens `link` with any scheme. The link is AI-supplied, from prompts built on file titles and tags. Allow only `http`/`https`. `SpeakerDetailView.swift:120`
- Failures that look like success:
  - Neglect `try?`s and dismisses even if the write failed.
  - Add YouTube Video's `save` returns silently on failure, and the sheet just stops spinning.
  - The bookmark context-menu Delete `try?`s.
  - Show an error. `RemovalDialogs.swift:67-76`; `AddYouTubeEpisodeView.swift:128-137`; `BookmarksSection.swift:256-259`
- `destination` for `.topic` and `.year` is rebuilt on every Home body pass while the page is pushed. `tracks(forTopic:)` is a DB read on main plus a full `tracks` filter, and `.year` re-filters the whole library. Load these inside `EpisodeListView`'s own `.task`. `HomeView.swift:108-109`, `:128-131`; `HomeLibraryViewModel.swift:214-218`
- `healCounts` decodes every transcript that mentions the term, on every open of the page, and writes. It could be skipped when no transcript has changed since the last heal (compare `updatedAt`). `TermDetailView.swift:188-205`
- `TermsPageView.focusedIndex` is a position. After a recount reorders the terms, the readout under the chart names a different term than the one the user picked. Store the focused term's ID. `TermsSection.swift:19`, `:28-30`

## Test gaps

- `AlbumDetailView`/`SpeakerDetailView`: opening and closing the page without typing writes nothing and leaves `metadataEditedAt` nil (P1 #1, P2 #9).
- Home route `.term(id)` still resolves after the term leaves the top 40 (P1 #2).
- Search: an out-of-order completion for an older query doesn't replace the current one's results (P1 #3). Changing the index re-runs the current query (P2 #3).
- `LibrarySearch.runSync`: "cafe" finds "Café", "ＡＩ" finds "AI", and an exact title match ranks first and survives the 200 cap (P2 #1–#2). `LibrarySearchTests` covers case and plain CJK substrings only.
- `PlaylistStore`: add, remove from the middle, then add. The order is stable and positions are unique. Re-adding is a no-op (P2 #14).
- `SpokenLanguagePicker` with no inherited language selects "Automatic", and picking English writes `"en…"` (P2 #17).
- `AddYouTubeEpisodeView` switching links replaces an auto-filled title (P2 #18).
