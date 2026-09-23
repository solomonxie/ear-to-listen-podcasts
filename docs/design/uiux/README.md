# UI/UX mockups — Ear to Listen Podcasts

Every surface drawn as it is built today. `../UIUX-DESIGN.md` carries the
reasoning and the copy rules; these files carry the pictures.

Glyphs follow the `uiux` skill (`references/notation.md` + `text-figma.md`):
`─●` on · `○─` off · `[ A | B ]` segmented (selected in CAPS) · `[[ x ]]`
primary · `[ x ]` secondary · `( x )` text button · `›` pushes · `⟳` working ·
`←` annotation · `!` destructive · `·` disabled.

## Screen map

```
 launch
   │
   ▼
 HomeView ── one scrolling page, no tab bar ─────────────────────┐
   │  🔍 search ──▶ results in place                             │
   │  shelves ──▶ AlbumDetail ──▶ [AlbumEdit] [AlbumAnalysis]    │
   │          ──▶ SpeakerDetail ──▶ [SpeakerEdit]                │
   │          ──▶ ShowDetail · PlaylistDetail ──▶ [AddTracks]    │
   │          ──▶ EpisodeList (year / topic)                     │
   │          ──▶ [Downloads]   [BookmarkEditor]                 │
   │  ── Sources ─▶ RemoteBrowser ─▶ RemoteBrowser (deeper) ─┐   │
   │                   └─▶ [SyncQueue] [FileInfo] [Preview]  │   │
   │  ── Settings ──▶ AiKeyDetail   [AddS3] [AddAiKey]       │   │
   │                                [Files picker · OS]      │   │
   └─ ▶ MiniPlayerBar (docked) ──▶ [RealPlayer] ─────────────┘   │
                                     ├ details ─▶ [EpisodeEdit]  │
                                     ├ transcript ─▶ TranscriptEditor
                                     │              [Edit phrase]  │
                                     │              [My corrections]
                                     └ [UpNext] [AddToPlaylist]  │
 ───────────────────────────────────────────────────────────────┘
 [brackets] = sheet · everything else pushes
```

## Files

| File | Covers |
|---|---|
| `home.md` | root page, search (incl. transcripts), shelves, empty state, mini player |
| `player.md` | Now Playing chrome, transport, scrubber, rail, Up Next |
| `transcript.md` | transcript controls, lines, corrections, editor page |
| `details.md` | episode detail cards, episode edit, bookmarks |
| `collections.md` | album / speaker / show / playlist / list screens |
| `sources.md` | Sources section (buckets + local folders), folder browser, file sheets |
| `queue.md` | global sync queue |
| `settings.md` | Settings section and its sheets |
| `components.md` | rows, cards, artwork, section typography |
