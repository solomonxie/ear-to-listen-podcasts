# 05 Transcription (`Library/Transcription`)

Files read in full: `TranscriptRunner.swift`, `AppleSpeechTranscriber.swift`, `AudioWindowFile.swift`, `OpenAIWhisperTranscriber.swift`, `TranscriptionEngine.swift`, `TranscriptFile.swift`, `TranscriptLines.swift`, `TranscriptSidecar.swift`, `TranscriptCoverage.swift`, `TimestampedText.swift`, `TranscriptPhraseSearch.swift`, `WordDiff.swift`, `README.md`. Also read, to confirm findings: `DB/TranscriptStore.swift`, `DB/Models/Transcript.swift`, `TrackStore.updateTranscriptPaths`, the runner's callers in `TranscriptPane.swift`, `PlaybackEngine.play/finishedPlaying` and `EarToListenApp` (foreground hook).

Summary: the parts are well built. The window plan, the gap and silence bookkeeping, the gate and watchdog around `SFSpeechRecognizer`, the sidecar language matching and the "Upload is the only write" rule all hold up. The pass orchestration is where it breaks. `run(engine:)` starts a pass only when nothing is stored, so an interrupted pass never resumes and "Replace" does nothing. Any error queues an automatic retry on every foreground, including errors that will never clear. Upload can get stuck, and it can write a language transcript over the untagged file. Merging lines across a window boundary silently does nothing. There is no queue: one pass at a time, owned by whatever is playing. **P0 0 · P1 6 · P2 13 · P3 20**

## P1

**1. `run(engine:)` starts a pass only when nothing is stored. An interrupted pass never resumes, and "Replace" does nothing.**
`TranscriptRunner.swift:369-377`, `:463-466`; `TranscriptPane.swift:133-142`, `:356-361`
- With no hand edits, `run` probes for a sidecar and then calls `startPass` only `if segments.isEmpty`. Every window is stored as it lands, so after the first window of any pass `segments` is non-empty.
- Every documented way of carrying on goes through `run`: the button, the "Replace" confirmation, and `resumeIfInterrupted()` on foreground. With stored text and no edits, each one does a sidecar probe and then nothing. No error, no spinner, and the status stays at "40% transcribed".
- Even with edits, "Replace" doesn't replace. The plan is built from gaps only (`:555-557`), so a complete transcript re-run with the other engine sends no windows. The dialog says "This replaces the transcript you already have on this phone".
- Scenario: the user starts on-device on a 2-hour episode and locks the phone. The background assertion expires at 30% (`:513-516`). Back in the app nothing resumes. Tapping On-device and confirming "Replace" does nothing either. The episode stays at 30% unless the user hand-edits a line, which turns the path on.
- Fix: in the sidecar task, start the pass whenever the sidecar import found nothing (`found == nil`), not when `segments.isEmpty`. Decide what "Replace" means. Either plan over the whole episode (merging still protects edits), or rename it "Fill the gaps" and drop the destructive wording. Add a test that drives `run` over a part-stored transcript.

**2. Any failure queues an automatic retry on every foreground, including failures that will never clear.**
`TranscriptRunner.swift:573-579`, `:591-595`, `:463-466`; `EarToListenApp.swift:52`
- The catch at `:577` sets `interruptedEngine` for every error: `missingAPIKey`, a Whisper 401 or 429 (`serverRejected`), `onDeviceModelMissing`, `notAuthorized` and `sliceFailed` alike. The silent-window limit at `:592` does the same.
- `resumeIfInterrupted()` runs on every `.active`. Each attempt re-decodes the window and, for Whisper, uploads it again: about 9.6 MB per 300 s window, plus a `bumpRequestCount`.
- Scenario: an expired OpenAI key. The first window fails, nothing is stored, so #1 doesn't block the retry. Every time the user comes back to the app, it uploads another 9.6 MB over cellular and shows the same error. A wrong language on-device instead re-recognises six windows (3 minutes of audio) per foreground, forever.
- Fix: set `interruptedEngine` only for transient causes (`CancellationError` from the expiry handler, URL errors, the watchdog's `requestFailed`). Cap automatic resumes, e.g. 3 per episode per day. Never auto-resume after the silent-window stop.

**3. Switching episode during an upload leaves `isUploading` true for good. Upload is disabled on every episode until relaunch.**
`TranscriptRunner.swift:340-341`, `:216-227`; `TranscriptPane.swift:210`
- `guard self.track?.id == track.id else { return }` returns before `isUploading = false`, and `attach(track:)` never resets it.
- Scenario: the user presses Upload, and the queue auto-advances (or they tap another episode) before the PUTs finish. From then on the button says "Uploading…" on every episode, and `uploadTranscript` bails at its `!isUploading` guard.
- Fix: reset `isUploading = false` before the track check, or reset it in `attach`. Keep the track check only for `lastError` and `uploadReport`.

**4. Upload writes a language transcript to the untagged file once anything but a sidecar has touched it, overwriting the other language.**
`TranscriptRunner.swift:131-132`, `:320`; `TranscriptSidecar.swift:91-102`
- `sidecarLanguage` is set only while every shown line has a `sidecar:` engine. One window from a pass (`onDevice`) or a file import (`file`) makes it nil, so `upload(... language: nil)` writes `ep1.vtt`, `ep1.lrc` and any untagged `.srt`, `.json` or `.txt`.
- Scenario: an episode has `ep1.vtt` (English, the publisher's) and `ep1.zh.vtt`. The episode language is zh, so the Chinese file loads. The user corrects one name, which enables a direct pass, then runs on-device to fill the 20 s music intro and presses Upload. The Chinese text replaces the English `ep1.vtt`. `ep1.zh.vtt` stays stale. The confirmation only says "transcript files sitting beside the audio".
- Fix: track the transcript's language separately from the engine string (a column on `transcripts`, or a runner property set on sidecar import and kept through passes and edits). Name the exact files in the confirmation dialog.

**5. Merging two adjacent lines across a silence marker silently does nothing, and that is the usual case at a window boundary.**
`TranscriptStore.swift:190-192`; `TranscriptPane.swift:530-535`; `TranscriptRunner.swift:633-637`, `:672-682`
- The pane checks contiguity against `lines` (silence markers dropped). The store checks it against stored `segments`, which still hold the empty markers that `padded` writes before and after each window's speech.
- A sentence cut by a 30 s window boundary is the main reason to merge (P2 #9), and those two lines almost always have a trailing or leading marker between them. The Merge button is enabled, the store returns the transcript untouched, and the selection is cleared.
- Fix: in `merge(trackID:starts:)`, check contiguity over non-empty segments only, and drop the silence markers inside the merged span. Add a test with a marker between the two lines.

**6. PLAUSIBLE: a window with no speech in it ends the pass on-device, and is sometimes reported as a missing language model.**
`AppleSpeechTranscriber.swift:146-148`, `:94-99`; `TranscriptRunner.swift:573-579`; `TranscriptCoverage.swift:66-70`
- On iOS the on-device recognizer usually answers silent audio with an error ("No speech detected", `kAFAssistantErrorDomain` 1110), not with an empty final result. `gate.finish(.failure(error))` passes it straight up, and the runner stops the whole pass on it. The `unheard` and silent-window logic (`:583-596`) never sees that window.
- When `supportsOnDeviceRecognition` read false (the false negative the comment at `:72-75` describes), the same error becomes `onDeviceModelMissing`, which tells the user to install a dictation language they already have.
- Tiny tail windows make it more likely. `windows` strides by 30 s, so a 30.3 s gap yields a 0.3 s window.
- Scenario: a show with a 45 s music intro. The first window is all music, and the pass stops at 0% with "No speech detected" or "This iPhone couldn't recognise en-US offline". Combined with #1 and #2, it never gets further.
- Fix: map the no-speech error to an empty result (`[]`), so `padded` records the window as silence through the existing `unheard` path. Map to `onDeviceModelMissing` only for the framework's actual asset errors. Fold a remainder shorter than `minimumGapSeconds` into the previous chunk.

## P2

**7. An unsupported audio language falls back to en-US silently, and the nonsense is stored as a finished transcript.**
`AppleSpeechTranscriber.swift:42-50`
- `resolvedLocale` returns `en-US` when no supported locale shares the language. The en-US model turns the speech into English-looking words, so windows are not empty. The silent-window guard doesn't fire, and the episode reads as "Whole episode transcribed", never to be looked at again. `TranscriptionContext` (`TranscriptionEngine.swift:68-70`) documents exactly this failure.
- Fix: throw `onDeviceUnavailable(locale:)` when an explicit language has no recognizer. Fall back to en-US only when no language was set.

**8. Each 30 s window rebuilds the recognizer and can wait up to 5 s for an availability flag.**
`AppleSpeechTranscriber.swift:61-76`, `:106-112`
- `authorize()`, `SFSpeechRecognizer(locale:)` and `becomesTrue` run per window. On phones where `supportsOnDeviceRecognition` stays false (the documented false negative), every window spends the full 5 s polling.
- Scenario: a 2-hour episode is 240 windows, about 20 minutes of idle waiting, on top of reloading the model each time. This also widens the presigned-URL window in #16.
- Fix: make the transcriber hold one recognizer and the flag result for the pass (a class or actor created in `transcribeWholeEpisode`). Poll once.

**9. Windows are hard 30 s cuts with no overlap, so words at every boundary are lost or garbled, and sentences split.**
`TranscriptCoverage.swift:66-70`; `AudioWindowFile.swift:54`, `:62-70`
- A word straddling the cut is half in each window. Each recognizer sees a fragment and either drops it or guesses. An hour of audio has 120 such cuts, and on-device keeps the window at 30 s on purpose.
- PLAUSIBLE: `AVURLAsset(url:)` is created without `AVURLAssetPreferPreciseDurationAndTimingKey`. On VBR MP3 without a seek table, `reader.timeRange` starts at an estimated offset, so window timestamps drift from the playback position as the episode goes on.
- Fix: decode each window with 1–2 s of overlap on both sides. Keep only words whose start lies inside the nominal window. Prefer cutting at a low-energy point near the boundary. Pass the precise-timing option for windows.

**10. PLAUSIBLE: an untimed final result puts the whole window's text at its first instant, with duplicate starts. Duplicate starts break line identity everywhere.**
`AppleSpeechTranscriber.swift:157-163`; `TranscriptLines.swift:59-66`, `:203-215`; `Transcript.swift:19`
- When no timed hypothesis was absorbed, `isFinal` falls back to `words`. The comment at `TranscriptLines.swift:144-149` says these routinely have every timestamp at 0. `grouped` then cuts 18-word lines that all start at `startOffset`, and `padded` records the rest of the window as silence, so it is never redone.
- `TranscriptSegment.id` is `start`. Duplicates also come from sidecars (two VTT cues at the same time, word-level Podcast Index JSON). With duplicates, `applyEdit` and `split` edit `firstIndex`, `merge(starts:)` takes both, `ForEach` and `TranscriptPhraseSearch.Hit` have colliding IDs, and tapping any of those lines seeks to the window start.
- Fix: when the final words are untimed, spread them with `TranscriptFile.interpolated(_, over: window)`, or treat the window as failed. In `normalized`, nudge equal starts apart by 1 ms so starts stay unique.

**11. PLAUSIBLE: a Whisper segment that ends past its window deletes the next stored line.**
`TranscriptRunner.swift:666`, `:672-682`; `TranscriptStore.swift:54-57`
- Whisper often reports a last `end` beyond the audio it was given. Nothing clamps incoming lines to `window.end`. `merging` drops any unedited existing line whose closed range overlaps an incoming spoken one, and a touching endpoint counts as overlap.
- Scenario: a gap [0, 120] ahead of a stored line at [120, 125]. Whisper's last segment ends at 120.6, so the line at 120 is dropped. The 120.6–125 hole is under `minimumGapSeconds`, so it is never re-transcribed. The text is lost without a trace.
- Fix: clamp each produced line to the window in `padded`. In `merging`, require overlap greater than a small epsilon (e.g. 0.05 s).

**12. Every window does a whole-transcript decode, merge, encode and write on the main actor, and republishes `lines`.**
`TranscriptRunner.swift:609-613`, `:30-32`, `:128-133`; `TranscriptStore.swift:36-41`, `:7-30`
- `store` → `transcriptStore.merge` → `find` (decode all segments), `merging` (O(existing × incoming)), `normalized` (sort), `save` (encode, an `existingCreatedAt` read, a write, and `ChangeLog.record`). All of it runs synchronously on the main actor, every few seconds during a pass.
- `segments.didSet` reassigns `lines` (the frozen copy) each time, so the transcript list re-diffs per window even though nothing visible changed.
- `applyEdit`, `mergeLines`, `splitLine`, `rejectLastPass`, `importFile` (file read and parse too) and `showSidecar` also decode and encode on main.
- Scenario: in the second hour of a pass, a 2,000-line transcript is decoded and re-encoded on the main thread every 5–10 s while the user scrolls the episode page. That breaks the CLAUDE.md "nothing heavy on the main actor" rule.
- Fix: move transcript writes to a background actor that keeps the decoded segments in memory for the pass. Publish `segments` only when the pass ends or when something is shown. Assign `lines` only when it actually changes.

**13. "No transcript" and "never synced" are both stored as nil, so opening any episode without a transcript probes five sidecar paths.**
`TranscriptSidecar.swift:31-37`, `:63-70`; `TrackStore.swift:629-632`; `TranscriptRunner.swift:246-247`, `:369-372`
- `updateTranscriptPaths` writes `sidecars[file.filePath]`, which is nil when the listing found none. `pathsToTry` reads nil as "unknown" and falls back to `candidatePaths` (vtt, srt, json, lrc, txt). That is five sequential `streamURL` + GET round trips per episode open, and again on every pass start.
- This is the "per-episode sidecar probe that cost five requests" CLAUDE.md names as one of the worst bugs. The doc comment at `TranscriptFile.swift:65-66` claims the opposite.
- Fix: store `[]` for "listed, none found" (`found ?? []`) and treat an empty array as definitive. Probe only when the value is nil.

**14. The empty-line split in the VTT/SRT parser needs exactly `\n\n`. A whitespace-only line or lone `\r` collapses the file into one cue.**
`TranscriptFile.swift:423-428`
- CRLF and BOM are handled, but "blank" lines containing spaces or tabs (common in tool-generated SRT) and classic-Mac `\r` line ends aren't. The whole file becomes one block. `parseVTT`/`parseSRT` take the first timing line and join everything after it, every later timing line included, into one segment.
- Scenario: a publisher's SRT with trailing spaces on its separator lines imports as a single line, "Hello 2 00:00:05,000 --> 00:00:08,000 Welcome …", covering 4 s. The rest of the episode looks untranscribed.
- Fix: normalise `\r\n` and `\r` to `\n`, then parse line by line, starting a new cue at any timing line (`-->`) and ending one at a whitespace-only line.

**15. Playing another episode, including auto-advance, kills the pass silently and forgets it.**
`TranscriptRunner.swift:216-218`, `:455-458`; `PlaybackEngine.swift:149`, `:297`
- `attach(track:)` calls `cancel()`, which clears `interruptedEngine`. A background pass on episode A ends the moment A finishes and B starts, with no message. Coming back to A doesn't resume it (and #1 would block a resume anyway).
- Fix: let the pass outlive the playing episode (key it by trackID, not `self.track`), or call `stopRunning()` with `interruptedEngine` kept per track, and say "Paused at 60%".

**16. The stream URL is resolved once per pass, and presigned URLs expire after an hour.**
`TranscriptRunner.swift:532-534`; `AudioWindowFile.swift:27-32`; `SigV4.swift:131`; `SharedKey.swift:78`
- Every window re-opens `AVURLAsset` on the same `audioURL`. An uncached S3/Azure episode that takes more than an hour (long episodes, #8 waits) gets 403s. Then `sliceFailed` or a reader error stops the pass partway.
- Fix: re-resolve `streamURL` per window or on an HTTP error, or resolve it once every 30 minutes.

**17. Editing or importing during a pass: edits disappear until it ends, and an imported file is overwritten by the pass.**
`TranscriptRunner.swift:438`, `:128-129`, `:396-409`, `:617-647`
- While `frozenLines` is set, `rebuildLines` ignores `segments`. A correction, merge or split saves, but the row reverts to the old text until the pass ends. The user sees their edit vanish.
- `importFile` isn't blocked during a pass. The pass keeps merging its windows, which were planned from the old gaps, over the imported lines, and `replacedSegments` is overwritten twice.
- Fix: disable editing and import while `isRunning` (the pane already disables Upload), or apply edits to `frozenLines` too. Cancel the pass in `importFile`.

**18. PLAUSIBLE: `language(ofSidecar:)` reads a dotted part of the filename as a language, so a file is labelled and uploaded under a wrong tag.**
`TranscriptFile.swift:46-50`, `:55-61`; `TranscriptSidecar.swift:42`, `:68`; `TranscriptRunner.swift:320`
- `sidecarSetsByAudioPath` correctly treats `show.the.vtt` as the untagged file of `show.the.mp3`. `language(ofSidecar:)` has no audio stem to compare against, so it returns `the` whenever `Locale.LanguageCode("the").isISOLanguage` (ISO 639-3 has many three-letter words: `the`, `doe`, `mas` and others).
- Effects: a "THE" language chip, the engine `sidecar:the`, and an Upload to `show.the.the.vtt`. The real file is left stale, and the next sync files the new one as a second language.
- Fix: record each sidecar's language at sync time (the map already knows it) instead of re-deriving it from the path. Or pass the audio stem into `language(ofSidecar:)`.

**19. An absurd timestamp in a sidecar crashes Upload and bookmarking.**
`TranscriptFile.swift:445-454`, `:397-418`; `TranscriptPane.swift:480`; `Bookmarks.swift:337`
- `clockTime` accepts any `Double`, e.g. `99999999999999999999:00:00.000`. The segment is stored. `vttTime`/`lrcTime` call `Int(total)`, and `Int(segment.start * 1000)` in the bookmark paths; both trap above `Int.max`.
- A crash, but only on a corrupt or hostile file, hence P2. The segment persists in the DB, so every Upload of that episode crashes.
- Fix: reject cue times that are non-finite, negative or over 48 h in `clockTime`, and over the duration where it is known.

## Improvements (P3)

- The watchdog's timeout calls `gate.finish`, not `gate.cancel`. The stuck `SFSpeechRecognitionTask` is never cancelled and keeps running on a WAV that `defer` has already deleted. `AppleSpeechTranscriber.swift:137-139`
- Partials are computed and thrown away. `TranscriptLines.split` runs every second, and `heard.absorb` (O(n²) `withoutRepeat`) runs on every callback, while the runner passes `{ _ in }`. Skip both when no `onPartial` is wanted. `AppleSpeechTranscriber.swift:157-166`; `TranscriptRunner.swift:663-665`
- `becomesTrue` uses `try? await Task.sleep`, so a cancelled pass still waits out the 5 s. `AppleSpeechTranscriber.swift:108-110`
- PLAUSIBLE: `absorbing` keeps heard words that start before the new hypothesis's first word. When a revision moves and rewrites its first word ("I" at 0.30 → "Ice" at 0.31), the old word stays in front ("I Ice cream"). `TranscriptLines.swift:83-89`
- VTT text isn't escaped or unescaped. `&amp;`/`&lt;` show literally on import, `strippingInlineTimestamps` deletes any literal `<…>` text, and the writer emits raw `<`, `&`, `-->` and blank lines from hand-edited text, which other players reject. `TranscriptFile.swift:303-324`, `:464-473`
- Any third-party `NOTE` containing "silence" plus a time span, or the word "edited", is taken as ours (silence marker, protected line). Require the `ear-to-listen` (or legacy) tag. `TranscriptFile.swift:166-173`
- LRC: a BOM on the first line drops that line (`blocks` strips it, `parseLRC` doesn't), and `[mm:ss:xx]` (colon before hundredths, common) is read as h:m:s. `TranscriptFile.swift:205-216`, `:457-460`
- JSON: one mistyped field (`"startTime": "1.5"`) fails the whole decode silently, an empty `speaker` produces ": text", and word-level Podcast Index files become one line per word. Decode per segment and group short adjacent segments. `TranscriptFile.swift:229-250`
- Sidecars and picked files are read as UTF-8 only. UTF-16 or GBK SRTs are treated as missing (`String(data:encoding:.utf8)` → nil) or as garbage (`String(decoding:)`). Try the BOM, then UTF-16 and the system encodings. `TranscriptSidecar.swift:122`, `:126`; `TranscriptRunner.swift:401`
- `vttTime`/`lrcTime` truncate instead of rounding (`1.005` → `00:00:01.004`), so each upload and re-import shifts starts by up to 1 ms, and `transcriptEdits.segmentStart` no longer matches its line. `TranscriptFile.swift:402`, `:416`
- Upload has no conditional write (ETag/`If-Match`), so a newer file written by another device is replaced without a check. A failure partway leaves `.vtt` new and `.lrc`/`.srt` old. A failed HEAD (`try?`) is read as "format not there", so a stale `.srt` survives. `TranscriptSidecar.swift:100-113`
- Temp WAVs from a killed or jetsammed pass are never swept. Add a launch sweep of `tmp/transcribe-*.wav`. `copyNextSampleBuffer` blocks a cooperative-pool thread for the whole remote decode, so run the reader on a dedicated queue. `AudioWindowFile.swift:56-58`, `:85`
- `recountTerms` doesn't run when a pass finishes on its own (`:440-450` skip `stopRunning`), nor after `importFile`, `showSidecar`, `importSidecar` or `rejectLastPass`. Term counts stay stale until the next episode change. `TranscriptRunner.swift:440-450`
- `rejectLastPass` restores the pre-pass snapshot, so corrections made after the pass are dropped, and their `transcriptEdits` rows point at lines that no longer exist. Re-apply edits whose `segmentStart` is still present. `TranscriptRunner.swift:420-426`
- `merging` keeps an incoming line that starts before an edited line and runs over it, so text is duplicated around a correction. Clip incoming spans to the edited spans. `TranscriptStore.swift:44-47`
- PLAUSIBLE: tapping Run before the stored transcript has loaded cancels the load task (`cancel()` → `sidecarTask?.cancel()`). If the sidecar probe returns first, the pass plans over the whole episode, costing Whisper money for text already stored. Await the load before planning. `TranscriptRunner.swift:236-248`, `:368-376`
- `inheritedLanguage` does two DB reads, and `EpisodeLanguageField(playing:)` calls it from a view initializer, so it runs per render. Cache it on `attach` and `setEpisodeLanguage`. `TranscriptRunner.swift:690-697`; `EpisodeLanguageField.swift:85`
- Whisper: `language` is cut at `-` only, so an ICU-style id (`zh_CN`) is sent whole and rejected. `no_speech_prob` isn't used, so hallucinated lines on silence ("Thanks for watching") are stored. `OpenAIWhisperTranscriber.swift:41-43`, `:65-82`
- Dead code: `TranscriptCoverage.isWorthFinishing` (tests only), `AppleSpeechTranscriber.isSupported`, `AppleSpeechTranscriber.lines(from:)`, `AudioWindowFile.localURL`, `OpenAIWhisperTranscriber.hasKey`.
- Doc drift: the README's VTT sample uses `NOTE byop` (the code writes `ear-to-listen`). `TranscriptSidecar` has two stacked doc comments on `pathsToTry` and `@discardableResult` between two halves of `upload`'s comment. The `windowSeconds` comment still describes seek-driven windows. `README.md:69-81`; `TranscriptSidecar.swift:15-31`, `:88-92`; `TranscriptionEngine.swift:54-55`

## Test gaps

- `run(engine:)` over a part-stored transcript with no edits. A pass must start, and `resumeIfInterrupted` must resume it (#1).
- A Whisper 401 and the silent-window stop. Neither may set up an automatic resume (#2).
- Upload, then `attach` to another track before completion. `isUploading` must be false (#3).
- A `sidecar:zh` transcript plus one `onDevice` window. Upload must target `ep1.zh.*` (#4).
- `merge(trackID:starts:)` with a silence marker between the two lines (#5).
- A silent window through `AppleSpeechTranscriber` (device test). It must come back as covered silence, not an error (#6).
- An untimed final hypothesis, and VTT with two cues at the same start. Starts must be unique (#10).
- `merging` with an incoming end just past an existing start (#11).
- VTT/SRT with whitespace-only separator lines and `\r` line ends (#14). A cue at `99999999999999999999:00:00` (#19).
- `language(ofSidecar:)` on `show.the.vtt` beside `show.the.mp3` (#18).
