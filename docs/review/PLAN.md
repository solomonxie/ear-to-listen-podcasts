# Code review plan

Started 2026-10-15 at `dc530fa`. Static review only: no builds and no simulators. One step at a time, and Mac load is checked before each step.
Findings for step N go in `NN-<area>.md`. Tick the box when a step is done.

## Per-step checklist

Apply each of these to every file in the step:

1. **Correctness**: logic bugs, edge cases (empty, nil, duplicates, unicode, huge input), off-by-one errors, wrong state transitions.
2. **Concurrency**: actor isolation, `@MainActor` misuse, `Sendable`, races, task cancellation, retain cycles in closures and tasks.
3. **Repo rules (CLAUDE.md)**:
   - Per-item I/O in loops.
   - Heavy work on the main actor or in a view `body`.
   - Long lists that aren't lazy.
   - Bursts that aren't coalesced, such as `libraryDidChange` without a debounce.
4. **Errors**: swallowed `try?`, silent failures the user should see, crash paths (`!`, `fatalError`, force casts, out-of-bounds indexing).
5. **Security and privacy**: secrets in code or logs, keychain use, URL and path injection, signature correctness.
6. **Performance and size**: redundant work, N+1 DB queries, missing indexes, unused code, and dependency weight.
7. **Design and simplification**: duplication, dead code, oversized types or functions, naming.
8. **Tests**: missing coverage for the risky paths found above.

Each finding gets a severity, a `file:line` reference, the problem, a failure scenario and a suggested fix:

- **P0**: crash or data loss.
- **P1**: wrong behavior or a security issue.
- **P2**: performance, or a breach of the repo rules.
- **P3**: cleanup or improvement.

## Steps (dependency order: data first, then UI)

- [x] 01 DB: `Sources/DB` (29 files, about 4.3k lines). Migrations, stores, `TrackMerge`, models, indexes, transactions.
- [x] 02 Playback: `Sources/Playback` (about 1.2k lines). `PlaybackEngine` state machine, `Cache`, `YouTubeEmbed`, audio session, interruptions.
- [x] 03 Providers and credentials: `Sources/Providers`, `Sources/Services`. S3 SigV4, Azure SharedKey, GCS service account, local files, listing and paging.
- [x] 04 Sync: `Library/Sync.swift`, `SyncQueueManager`, `SyncJobStore` usage. Per-item I/O, retries, cancellation.
- [x] 05 Transcription: `Library/Transcription`. Runner, Apple Speech, transcript file and lines, merge and split.
- [x] 06 AI: `Library/AI` and the chat client. Key gating (China rejection), prompts, error handling, cost.
- [x] 07 Rest of Library: everything in `Sources/Library` not covered by 04–06 (summary, artwork sidecar, search, YouTube).
- [x] 08 Backup: `Sources/Backup`. Snapshot, auto-backup, cloud drive, archive naming, restore safety.
- [x] 09 Importers and extensions: `Sources/Importers`, `Extensions`. Spotify, share inbox, YouTube links.
- [x] 10 Player screens: `Screens/Player` (about 4k lines). `RealPlayerView`, `TranscriptPane`, bookmarks, details.
- [x] 11 Home, playlists and terms screens: `Screens/Home`, `Screens/Playlists`, `Screens/Terms`.
- [x] 12 Settings and remote screens: `Screens/Settings`, `Screens/Remote`.
- [x] 13 App shell and CarPlay: `Sources/App`, `Sources/CarPlay`. Lifecycle (UIScene), CarPlay templates, shared UI helpers.
- [x] 14 Build, config and scripts: `project.yml`, `Makefile`, `scripts/`, `Config/`, Info.plist, secrets hygiene, release size.
- [x] 15 Tests: `Tests` (49 files). Coverage gaps against findings 01–14, flaky patterns.
- [x] 16 Summary: `SUMMARY.md`, with the top issues ranked across all steps and a suggested fix order.

## Progress log

| Time | Step | Load (1m/ncpu) | Note |
|---|---|---|---|
| 2026-10-15 08:43 | 01 | - | P0 1 / P1 3 / P2 11 / P3 16 |
| 2026-10-15 08:46 | 02 | - | P0 0 / P1 5 / P2 6 / P3 14 |
| 2026-10-15 08:52 | 03 | - | P0 0 / P1 5 / P2 2 / P3 16 |
| 2026-10-15 09:21 | check | 17.0/10, pressure 1, 58Gi free | 3/16 done, 04 in flight |
| 2026-10-15 09:23 | 04 | - | P0 0 / P1 3 / P2 9 / P3 13 |
| 2026-10-15 09:29 | 05 | - | P0 0 / P1 6 / P2 13 / P3 20 |
| 2026-10-15 09:42 | 06 | - | P0 0 / P1 4 / P2 7 / P3 18 |
| 2026-10-15 09:49 | 07 | - | P0 0 / P1 1 / P2 8 / P3 11 |
| 2026-10-15 09:57 | 08 | - | P0 1 / P1 5 / P2 9 / P3 12 |
| 2026-10-15 10:01 | 09 | - | P0 0 / P1 0 / P2 2 / P3 9 |
| 2026-10-15 10:09 | 10 | - | P0 1 / P1 5 / P2 7 / P3 14 |
| 2026-10-15 10:17 | 11 | - | P0 0 / P1 3 / P2 18 / P3 16 |
| 2026-10-15 10:19 | check | 12.31/10, pressure 1, 56Gi free | 11/16 done, 12 in flight |
| 2026-10-15 10:43 | 12 | - | P0 0 / P1 3 / P2 11 / P3 18 |
| 2026-10-15 10:50 | 13 | - | P0 2 / P1 0 / P2 4 / P3 12 |
| 2026-10-15 10:56 | 14 | - | P0 0 / P1 1 / P2 1 / P3 10 |
| 2026-10-15 11:02 | 15 | - | P0 0 / P1 2 / P2 8 / P3 6 |
| 2026-10-15 11:15 | 16 | - | summary written |
