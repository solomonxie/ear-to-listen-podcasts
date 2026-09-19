# Sync queue

`Sources/Screens/Remote/SyncQueueView.swift` — one queue for every
connection. Reached from a source's `Queue (N)` pill, the browser footer's
`⟳ Syncing…`, or the browser's `⋯ → Queue`.

```
                    Queue
 ⏸ Paused. Nothing is being added to the queue and nothing
   is being processed.                       ← banner, only when it applies
 ⊗ Queue full (100). Files past this point come in as room frees up.  (orange)
 <notice>                                    ← manager.notice, secondary
 ┌ Queue (87/100) ──────────────────── ⏸  ⋯ ┐ ← unfinished vs the ceiling,
 │ ep-004.mp3                                │   not the total
 │ slmx-archives2         Reading tags   ⟳   │ ← says WHICH slow thing
 │ ep-005.mp3                                │
 │ slmx-archives2              Waiting       │
 │ ep-002.mp3                                │
 │ slmx-archives2                        ↻   │ ← failed keeps its row and a
 │ 403 SignatureDoesNotMatch                 │   retry: it needs a decision
 │ ep-003.mp3                                │
 │ slmx-archives2                        ✓   │
 │            Load 1,184 more…               │ ← 100 per page
 └───────────────────────────────────────────┘

 ⋯ menu   Speed: 3 at a time      [−] 3 [+]
          ──────────
          Clear Synced
          Clear Queue  !

 empty    Nothing queued. Sync a folder from a remote source to add
          files here.
```

Header controls act on the list right below them, so they sit on the header
rather than in a settings block.

Per-row status, all four:

```
 pending   Waiting
 running   Reading tags ⟳ / Asking AI ⟳ / Saving to library ⟳
 done      ✓ green
 failed    ↻ orange, error line under the filename
```

**Paused means paused** — nothing new is accepted, a whole-bucket pass refuses
to start, and the background schedule sits out. One control, one meaning.

**Ceiling of 100 unfinished jobs.** A bucket with thousands of files would
otherwise queue every one — hours of work nobody asked for, in a list nobody
can read. Listing stops at the ceiling and says so.

**It tops itself back up.** A connection that stopped at the ceiling is
re-listed when the queue drains empty, and the next hundred go in — repeating
until the bucket is done. The ceiling caps what's *waiting*, not what gets
imported, so nobody has to tap Sync Now once per hundred files.

**Listing and importing are separate.** A whole-bucket pass queues and returns
in seconds; the queue does the importing, at the speed set here. That's why the
`[−] N [+]` control applies to a "Sync Now" too, and why a bucket of thousands
no longer freezes the button that started it.
