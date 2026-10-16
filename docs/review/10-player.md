# 10 Player screens (`Sources/Screens/Player`)

Files read in full: `RealPlayerView.swift`, `TranscriptPane.swift`, `EpisodeDetailsPane.swift`, `EpisodeEditView.swift`, `EpisodeSummaryView.swift`, `Bookmarks.swift`, `EpisodeAudioSection.swift`, `EpisodeLanguageField.swift`, `MiniPlayerBar.swift`, `SpeakerAlbumField.swift`. Also read, to confirm findings: `TranscriptRunner` (published state, `rebuildLines`, `attach`, `currentLine`, editing), `TranscriptPhraseSearch`, `TranscriptStore.find`, `TrackStore.upsert`/`saveEdit`/`setLanguage`, `PlaybackEngine.showEdit` and its time observer, `MomentMark`, `ContentView` (how the player is mounted), `ScrollHandle` signature, `RemoteBrowserView` view-model use, `SettingsViewModel.load`, `BookmarkInsightsView` init.

Already covered elsewhere and not repeated: `saveEdit` writing back every column (01 #3). Merge adjacency in the pane vs the store (05). Edits invisible while `frozenLines` is set (05). Duplicate `start` IDs in `ForEach` and hits (05). `EpisodeEditView` running `readiness` on main (06). `suggest` bumping `analyzeRequest` after a failed call (06). Summary only offered for complete transcripts (06).

**Index-based `ForEach`: clean.** Every list is keyed by a stable ID (`segment.start`, `bookmark.id`, `track.id`, `file.id`). The one `id: \.offset` (`TranscriptPane.swift:224`, language chips) only reuses chip identities, with no indexing into a mutable array. `UpNextView` slices `engine.queue` with an index computed in the same body pass. No crash path found.

**Lazy containers: fine.** Transcript lines are a `LazyVStack` of `.equatable()` rows, hits are a `LazyVStack`, and Up Next is a `List`. `currentLine(at:)` is a binary search. Auto-scroll to the spoken line is `onChange(of: spokenStart)`, and it fires once per line change, not per tick.

Summary: the transcript rows are built carefully, but the page around them is not. `RealPlayerView` observes the whole `PlaybackEngine`, so every 0.5 s tick re-runs the 1k-line page body. It also re-runs the details card, the summary parse, the transcript pane body (which observes the engine again, unused), pushed destinations that read the DB, and an open Edit sheet's `init`. The serious bugs are all one shape: state that outlives a track change. The Edit Episode sheet retargets itself onto the next episode with the old episode's fields still in it, and Save, Cancel or Delete then corrupt the wrong row. The language picked in Edit Episode is never saved. **P0 1 · P1 5 · P2 7 · P3 14**

## P0

**1. The Edit Episode sheet silently retargets to the next episode, and Save, Cancel or Delete then act on the wrong row.**
`EpisodeDetailsPane.swift:54`, `:97`; `EpisodeEditView.swift:10`, `:261-269`, `:271-301`, `:303-311`
- The sheet content is `EpisodeEditView(track: track)`, where `track` is `latest ?? playingTrack`. Playback keeps running under the sheet. When the episode changes (auto-advance at the end, a remote "next" command, AirPods), `load()` sets `latest` to the new episode. The sheet closure is re-evaluated with episode B, and SwiftUI keeps the view's `@State`. So `let track` is B while `title`, `artistName`, `albumName`, `year`, `notes`, `language` and `artworkFileName` still hold A's values.
- Save: `updated = track` (B) gets A's title, speaker, album, year, notes and artwork, and `saveEdit` writes it. B's metadata is overwritten. Because `artworkFileName != track.artworkFileName`, B's own artwork file is also deleted (`:294-296`).
- Cancel: `discardIfUncommitted(artworkFileName)` compares A's committed artwork with B's and deletes A's artwork file from disk (`:266-268`). A's row still points at it.
- Delete Episode: B is now playing, so `deleteEpisode` unloads B and deletes B. The dialog doesn't name the episode, and the fields on screen still show A.
- Scenario: open Edit Episode two minutes before the end, think about a title, and the episode rolls over. Pressing Cancel loses A's artwork. Pressing Save renames B as A.
- Fix: snapshot on tap with `@State var editing: Track?` and `.sheet(item: $editing) { EpisodeEditView(track: $0) }`. Apply the same to `AddToPlaylistSheet(track: track)` (`:94-96`), which has the same retargeting.

## P1

**1. The language picked in Edit Episode is never saved.**
`EpisodeEditView.swift:272`, `:281-292`; `TrackStore.swift:382-388`, `:53`
- `save()` first calls `setLanguage(id:language:)`, then `saveEdit(updated)` with `updated = track`, whose `language` is the value from when the sheet opened. `upsert` does `row.save(db)` with every column, so the old language is written straight back.
- This is a deterministic instance of 01 #3, not a race: the sheet reverts its own write on every Save.
- Scenario: set Language to 中文 on an episode tagged English and press Save. Reopen the sheet and it says English, and the next transcription pass uses the English recogniser. The user gets confident nonsense, which the picker's own comment warns about.
- Fix: set `updated.language = language` before `saveEdit` and drop the separate `setLanguage` call. 01's fix (targeted `UPDATE`) also covers it.

**2. ✨ on the details card can write episode A's suggested metadata onto episode B, and then pay for B's summary.**
`EpisodeDetailsPane.swift:416-438`, `:347-369`, `:290-298`; `EpisodeSummaryView.swift:101-104`, `:214-227`
- `suggest()` awaits the AI call (seconds), then writes `title`/`artistName`/`albumName`/`year` and calls `save()`. If the track changed during the call and `load()` for B has finished, `fillFields` has set `draftTrackID` to B, so `save()`'s guard (`draftTrackID == track.id`) passes. A's suggestion is saved onto B.
- It then bumps `analyzeRequest`. The summary view, now showing B, runs `summarizer.run(track: B)`, which is a paid call nobody asked for on B. If the summary run itself spans a track change, `summary = result.summary` shows A's summary under B (`EpisodeSummaryView.swift:220`).
- Scenario: tap ✨ near the end of an episode and auto-advance happens while the model answers. The next episode is renamed and summarised.
- Fix: capture `let id = track.id` before the await, and return without touching fields or `analyzeRequest` if `track.id != id` afterwards. In `analyze`, drop the result if `track.id` changed.

**3. `readiness` (whether ✨ is offered) is computed for the previous episode.**
`EpisodeDetailsPane.swift:112-117`, `:54`
- On a track change both `.task(id: playingTrack.id)` blocks start together. The readiness task reads `track`, which is `latest ?? playingTrack`, and `latest` still holds the old episode until `load()` lands. So readiness is A's. It is also never recomputed when a transcription pass finishes, because the task is keyed only on the track ID.
- Scenario: go from a transcribed episode to an untranscribed one in Up Next. The Summary section and ✨ appear on B and fail. Going the other way, B's finished transcript never offers ✨ until another episode is played.
- Fix: compute from `playingTrack` (`let episode = playingTrack`), and key the task on `"\(playingTrack.id)|\(transcript.isComplete)"` (or listen for the runner's completion).

**4. A line open for correction is orphaned when the lines change, and the page stays in edit mode with no way out.**
`TranscriptPane.swift:46-47`, `:92-94`, `:114`, `:643-649`, `:681-684`; `RealPlayerView.swift:128`
- `editingStart`, `editText`, `selection` and `splitting` are never reset when the track changes or the lines are replaced. Only `loadError` is reset (`:114`).
- If the edited line's `start` disappears (a track change from the lock screen or AirPods, a pass finishing and replacing the lines, a sidecar language switch, or a merge from 05's path), the editor row vanishes with its text. `editingStart` stays non-nil, so `isEditingLine` stays true. The docked transport bar is hidden for good (`RealPlayerView.swift:128`), and auto-follow never scrolls again (`:682` guard).
- A stale `selection` has the same effect. Every row of the new episode shows tick circles and the engine buttons are disabled, but there is no selection bar (no `barStart` matches), so there is no Done button until a line is ticked.
- Scenario: start correcting a line, and the episode is skipped with a double-tap on AirPods. On the next episode the bottom bar never comes back, and Follow does nothing, until the page is closed.
- Fix: `.onChange(of: transcript.track?.id)` should clear `editingStart`, `selection`, `splitting`, `pickedFile` and `hits`. `.onChange(of: transcript.lines)` should clear `editingStart` and `selection` when their starts are no longer present.

**5. The bookmark editor's ‹ › step onto silent gaps.**
`Bookmarks.swift:323-339`, `:424-427`; `TranscriptStore.swift:101-106`; `TranscriptRunner.swift:675-679`
- The editor steps through `TranscriptStore.find`, which returns stored segments including the empty-text silence markers that passes write (`text: ""`). The runner filters these out of `lines`, but the editor doesn't.
- A step lands on a silence: the timestamp moves to the start of a gap, `spoken` becomes "" and the line text disappears. A mark made in a pause has its own `lineIndex` resolve to the silence, so "the line before" is the line before the gap rather than the one spoken.
- Scenario: mark late and press ‹ to walk back a line. The card shows a bare time with no words, which is the opposite of the "pick by reading" design.
- Fix: `lines = …filter { !$0.text.isEmpty }`, or reuse `TranscriptRunner.shared.lines` when `bookmark.trackID` is the attached track.

## P2

**1. The whole player re-renders on every 0.5 s playback tick.**
`RealPlayerView.swift:6`, `:105-118`, `:258-287`, `:639-660`, `:1036-1053`; `TranscriptPane.swift:17`, `:634`; `EpisodeDetailsPane.swift:97`; `EpisodeEditView.swift:35-46`; `EpisodeSummaryView.swift:148`
- `RealPlayerView` observes `PlaybackEngine`, whose `currentTime` publishes every 0.5 s (`PlaybackEngine.swift:495-500`). Each tick re-runs the page body and does all of the following:
  - It builds `transcript.lines.map { AnyHashable($0.start) }`, an N-element array of boxed values, for the scroll handle.
  - It rebuilds `EpisodeDetailsPane`, `NotesPane` and `TranscriptPane`. All three take closures, so none can be skipped, and their bodies run. That includes `EpisodeSummary.attributed(summary)` parsing the summary for timestamps on every tick, and `facts` doing Locale lookups.
  - `TranscriptPane` re-runs its body every tick anyway: it holds `@ObservedObject private var engine = PlaybackEngine.shared` and never reads it. The `engine` names in the file are all shadowing parameters. Its body then scans every line for `barStart` (`:634`) even when nothing is selected, and walks the whole `ForEach` ID list. The comment at `:18-22` describes a saving that doesn't happen.
  - Pushed pages are rebuilt too. `destination` does `libraryStore.artist/album` or `providerStore.all()` on main, and creates a fresh `SettingsViewModel()` for `RemoteBrowserView`'s `@ObservedObject`.
  - An open Edit sheet's content is re-evaluated, so `EpisodeEditView.init` does two DB reads on main per tick.
- `UpNextView` observes the engine too, and copies three slices of the queue (the whole library, in the worst case) plus a `firstIndex` scan every tick.
- Scenario: a 2-hour episode with ~2,000 lines plays with the page open and Speaker pushed. That is four full-page body passes a second, about 2k-element allocations, and DB reads on main, while the user scrolls. CLAUDE.md: "nothing heavy on the main actor… a view body… may not scan a library."
- Fix:
  - Split the clock out. Add a small `PlaybackClock: ObservableObject` (or `@Observable`) that publishes only `currentTime`, and let only `SeekBar`, the docked bar, the YouTube link and a tiny `SpokenLineTracker` child observe it. The tracker publishes `spokenStart` only when the line changes.
  - The page observes only `currentTrack`, `isPlaying` and `youTubeDisplay`.
  - Delete the unused `engine` from `TranscriptPane`.
  - Cache the scroll handle IDs in `TranscriptRunner` alongside `lines`.
  - Load destination models in the pushed view's own `.task`.

**2. PLAUSIBLE: the seek bar writes its global frame into page state on every scroll frame.**
`RealPlayerView.swift:19`, `:247-250`, `:980`
- `SeekBar` sits inside the page's `ScrollView` and does `.onChange(of: geo.frame(in: .global)) { area = $1 }`, bound to `RealPlayerView`'s `@State seekBarArea`. While the page scrolls, that frame changes every frame, so the parent's state is written at 60–120 Hz. If SwiftUI invalidates the page on those writes, every scroll frame costs a full #1 body pass. The value is only ever read inside the swipe gesture's `canBegin`.
- Scenario: flicking through the transcript stutters on older phones, and the stutter is worst on the longest transcripts.
- Fix: keep the rect in a non-observed reference box (`final class Box { var rect }` held in `@State`), or report the frame in the scroll's coordinate space plus the content offset only when a swipe begins.

**3. In-episode search runs on the main actor, per keystroke, and goes stale when the lines change.**
`TranscriptPane.swift:87-89`; `TranscriptPhraseSearch.swift:26-38`
- `.task(id: searchQuery)` inherits the view's main actor. `hits(for:in:)` lowercases every line again on every keystroke, with no debounce. CLAUDE.md wants haystacks folded once and scanned off-main.
- The task is keyed only on the query, so after a language switch, an edit, a merge or a pass finishing, the hit list keeps showing old texts and starts. A tap seeks to a time and scrolls to an ID that may no longer exist.
- Scenario: type "ferry dawn" in a 3-hour Chinese transcript. Each character re-lowercases ~3,000 lines on main while the keyboard animates. Switch the transcript from 中文 to English, and the hits still show the Chinese lines.
- Fix: keep a folded (`lowercased`) copy in `TranscriptRunner`, rebuilt in `rebuildLines`. Key the task on `"\(searchQuery)|\(transcript.lines.count)|\(revision)"`, sleep 150 ms, and scan in `Task.detached`.

**4. Database reads and transcript decodes on main in screen code.**
- `BookmarkEditorView.task` decodes the whole transcript (`TranscriptStore.find`) on main while the full-screen cover animates in. The comment says "off the body", but it is still the main thread. `Bookmarks.swift:424-427`
- `addTerm` decodes the whole transcript and joins it into one string on main, inside an alert action. `EpisodeDetailsPane.swift:315-325`
- `inheritedLanguageLabel` is a computed property read in `body`, and does up to two DB reads per body pass. The body re-runs on every keystroke in Title, Speaker or Notes. `EpisodeEditView.swift:50-59`, `:105`
- `SpeakerAlbumField` queries albums on every keystroke in Speaker (`task(id: filedSpeaker)`, no debounce). `SpeakerAlbumField.swift:25-27`
- Fix: read in `Task.detached` and assign on return. Compute the inherited label once in `init` or a `.task`. Debounce the album lookup by 250 ms.

**5. Neither seek bar can be moved with VoiceOver.**
`RealPlayerView.swift:946-992`, `:789-791`
- `SeekBar` has no accessibility element, label or value. VoiceOver reads two loose time labels and the drag area is unreachable. `BarSeekLine` has a label and value, but no `accessibilityAdjustableAction`. On a page that exists to move around in spoken audio, a VoiceOver user can only use ±10 s.
- Fix: `.accessibilityElement()`, `.accessibilityLabel("Position")`, `.accessibilityValue("… of …")`, and `.accessibilityAdjustableAction { $0 == .increment ? onSeek(currentTime + 30) : onSeek(currentTime - 30) }` on both.

**6. The speaker and album under the title stay stale after an edit.**
`RealPlayerView.swift:137-141`, `:205-208`, `:425-434`; `PlaybackEngine.swift:112-114`
- `artist`/`album` load in `.task(id: track.id)`. Saving a new speaker or album in Edit Episode updates `engine.currentTrack.artistID`/`albumID` (the engine's `displayKey` includes them), but the ID doesn't change, so the task doesn't re-run. The title subtitle and "Speaker: …" keep the old name, and tapping "Speaker: Old" pushes the old speaker's page.
- Fix: key on `"\(track.id)|\(track.artistID ?? "")|\(track.albumID ?? "")"`, or pass in the artist and album the details card already loads. It loads them anyway, so this is duplicate work.

**7. PLAUSIBLE: a late `load()` can paint the previous episode into the details card.**
`EpisodeDetailsPane.swift:119-126`, `:272-299`
- The detached read isn't cancelled with its task. The guard `playingTrack.id == loaded.track.id` compares against the `self` captured when the task started, so it always passes. A debounced `libraryDidChange` reload created just before an auto-advance (the engine marks the episode listened, then advances) runs `load()` for A 400 ms later and sets `latest`, `artist`, `terms`, `copies` and `draftTrackID` back to A while B plays.
- Fix: hold `@State var loadedID`, set it from the current `playingTrack.id` before each load, and drop results whose `track.id` differs from it on return. Or drive the reload through `.task(id: "\(playingTrack.id)|\(reloadCount)")` so SwiftUI cancels stale ones.

## P3

- Opening Edit on a second line while one is open overwrites `editText`, and the first correction is lost without a prompt. Save the first, or ask. `TranscriptPane.swift:566-572`
- VoiceOver gaps in the transcript:
  - The search toggle (`magnifyingglass`/`xmark`), the clear-query button, and the inline editor's ✓/✕ have no labels and fall back to symbol names. `TranscriptPane.swift:253-274`, `:289-294`, `:792-799`
  - The spoken line is shown only by weight. Add `.accessibilityAddTraits(isCurrent ? .isSelected : [])` or a "Now playing" value. `TranscriptPane.swift:733-743`
- From the player, `RemoteBrowserView` gets a `SettingsViewModel()` that is never `load()`ed and is rebuilt each render. `providers` is always empty, so the "dismiss when this connection is deleted" `onChange` never fires, and a browser for a deleted source stays on screen. Pass a loaded model held in `@StateObject`. `RealPlayerView.swift:651-658`; `RemoteBrowserView.swift:219-221`
- Bookmarks are read twice per change:
  - `markMoment` refreshes and so does the `bookmarksDidChange` it triggers.
  - `NotesPane.delete` posts and calls `onChange`.
  - The editor's `onDismiss: onChange` duplicates the notification.
  - `MiniPlayerBar` fetches every bookmark to count them (`MomentMark.count`).
  - Rely on the notification alone, and use `SELECT COUNT(*)` for the count. `RealPlayerView.swift:142-144`, `:265`, `:600`; `Bookmarks.swift:183`, `:272-276`; `MiniPlayerBar.swift:29-32`
- Failures are swallowed where the user believes the action worked:
  - `toggleListened`/`toggleFavorite` show the change optimistically and never roll it back on a `try?` failure.
  - `BookmarkEditorView.save`, `EpisodeEditView.save` and `EpisodeSummaryView.save` dismiss or close on failure, and the typed text is lost.
  - Keep the sheet open and show the error. `RealPlayerView.swift:574-592`; `Bookmarks.swift:430-438`; `EpisodeEditView.swift:292-300`; `EpisodeSummaryView.swift:206-212`
- The old artwork file is deleted even when `saveEdit` failed, which leaves the row pointing at a missing file. Delete only after a successful save. `EpisodeDetailsPane.swift:402-409`; `EpisodeEditView.swift:292-296`
- `artworkItem` is never reset after a pick, so picking the same photo again doesn't fire `onChange`. Set it to `nil` after handling. `EpisodeDetailsPane.swift:127-129`; `EpisodeEditView.swift:209-211`
- PLAUSIBLE: on a one-character line (common in Chinese: "嗯", "对"), `SplitPhraseSheet` builds `Slider(in: 1...1, step: 1)`. A zero-width stepped range is a known trap risk. Don't offer Split for lines under two characters. `TranscriptPane.swift:878`, `:763`
- Tapping the dimmed backdrop of the bookmark editor is Cancel, and it throws away a typed note without asking. Ask when `note` changed. `Bookmarks.swift:357-359`
- `RealPlayerView` reads `transcript.lines` without observing the runner. While paused (and editing always pauses), `spokenStart` and the scroll-handle IDs don't update when the transcript loads, a merge or split lands, or the language switches. The highlight is missing or points at a removed line until playback resumes. This is fixed with P2 #1's `SpokenLineTracker` observing both. `RealPlayerView.swift:64`, `:105-107`, `:275`
- `EpisodeLanguageField` has no caller. Delete it. `EpisodeLanguageField.swift:1-93`
- `EpisodeDetailsPane` still carries the old inline form (`title`, `artistName`, `albumName`, `year`, `notes`, `savedSnapshot`, `draftTrackID`, `fillFields`, `save`), now used only by `suggest`. Move the suggestion into `EpisodeEditView` (which already has it) or write only the suggested fields with a targeted update, and delete the rest. `EpisodeDetailsPane.swift:28-39`, `:333-369`
- Oversized files. Split them:
  - `RealPlayerView.swift` is 1,166 lines holding seven types. Move out `NowPlayingBarContent`+`BarSeekLine` (`PlayerBar.swift`), `SeekBar`, `UpNextView` and `MarkCountBadge`. Inside the page, extract `PlayerTransport` and `PlayerHeader` views so only they observe the clock.
  - `TranscriptPane.swift` is 1,002 lines. Move out `SplitPhraseSheet`, `TranscriptEditsView`, `InlinePhraseEditor` and the search bar and hit list (`TranscriptFindBar`), and keep the lines list as its own view.
- `EpisodeSummaryView.errorMessage` survives a track change, so B shows A's "AI failed" text. Clear it in the `onChange(of: track.id)`. `EpisodeSummaryView.swift:106-110`

## Tests to add

- Edit Episode: with the sheet open on A, swap the presenter's track to B. Save must write to A (or refuse), and Cancel must not delete A's artwork (P0).
- `EpisodeEditView.save` with only the language changed persists the new language (P1 #1).
- `suggest` across a track change writes nothing to B and doesn't bump `analyzeRequest` (P1 #2).
- `TranscriptPane`: begin an edit, then `attach` a new track. `isEditingLine` is false and the selection is empty (P1 #4).
- Bookmark editor stepping over a transcript with silence segments lands only on lines with text (P1 #5).
- `TranscriptPhraseSearch` over 5k lines runs off-main, and the hits refresh after `lines` changes (P2 #3).
