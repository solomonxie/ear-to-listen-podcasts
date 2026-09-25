#!/usr/bin/env python3
"""What a backup archive actually holds — run it over every candidate copy and the
one worth restoring is the one with numbers in it.

Usage: scripts/inspect-archive.py <archive.zip> [more.zip ...]
       scripts/inspect-archive.py --details <archive.zip>   # every bookmark and correction
"""
import json
import sys
import zipfile


def read(path):
    with zipfile.ZipFile(path) as archive:
        return json.loads(archive.read("snapshot.json"))


def summarize(path, snapshot):
    episodes = snapshot.get("episodes", [])
    transcripts = snapshot.get("transcripts", [])
    bookmarks = [b for e in episodes for b in e.get("bookmarks", [])]
    counts = {
        "playlists": len(snapshot.get("playlists", [])),
        "sources": len(snapshot.get("providers", [])),
        "speakers": len(snapshot.get("artists", [])),
        "episodes": len(episodes),
        "favourites": sum(1 for e in episodes if e.get("isFavorite")),
        "notes": sum(1 for e in episodes if e.get("notes")),
        "summaries": sum(1 for e in episodes if e.get("summary")),
        "bookmarks": len(bookmarks),
        "bookmark notes": sum(1 for b in bookmarks if b.get("note")),
        "transcripts": len(transcripts),
        "corrections": sum(len(t.get("edits", [])) for t in transcripts),
    }
    print(f"{path}  (v{snapshot.get('version')}, exported {snapshot.get('exportedAt')})")
    if not any(counts.values()):
        print("  EMPTY — this is a backup of a library with nothing in it")
    for name, count in counts.items():
        if count:
            print(f"  {count:5d}  {name}")
    print()


def details(snapshot):
    for episode in snapshot.get("episodes", []):
        lines = []
        if episode.get("notes"):
            lines.append(f"    note: {episode['notes']}")
        for bookmark in episode.get("bookmarks", []):
            at = bookmark["positionMs"] // 1000
            lines.append(f"    {at // 60:02d}:{at % 60:02d}  {bookmark.get('note') or ''}")
        if lines:
            print(f"  {episode['title']}  [{episode['filePath']}]")
            print("\n".join(lines))
    for transcript in snapshot.get("transcripts", []):
        for edit in transcript.get("edits", []):
            print(f"  {transcript['filePath']} @ {edit['segmentStart']:.1f}s")
            print(f"    was: {edit['originalText']}")
            print(f"    now: {edit['editedText']}")


if __name__ == "__main__":
    paths = [a for a in sys.argv[1:] if a != "--details"]
    if not paths:
        sys.exit(__doc__)
    for path in paths:
        try:
            snapshot = read(path)
        except Exception as error:  # a truncated download, a zip that isn't one of ours
            print(f"{path}\n  unreadable: {error}\n")
            continue
        summarize(path, snapshot)
        if "--details" in sys.argv:
            details(snapshot)
