#!/usr/bin/env python3
"""Caption English audio locally with Whisper on Apple Silicon (MLX).

Writes <audio>.vtt and <audio>.lrc beside each file; audio that already has a .vtt is
skipped. A file that fails is retried only after 2h (marker: <audio>.vtt.failed).
--embed also writes the lyrics into an .m4a's own tags.

Usage:
  venv/bin/python scripts/transcribe/caption_en.py PATH... [--limit N] [--shard i/n] [--embed]
"""
import argparse
import datetime
import os
import time
import zlib

from cues import clamp_ends, find_audio, write_sidecars

MODEL = "mlx-community/distil-whisper-large-v3"
LANG = "en"
MAX_CUE_CHARS = 84
MAX_CUE_SECS = 7.0
RETRY_FAILED_SECS = 2 * 3600


def log(msg):
    print(f"{datetime.datetime.now():%m-%d %H:%M:%S} {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--shard", default="0/1", help="i/n: only files whose path hashes to i mod n")
    ap.add_argument("--embed", action="store_true", help="also embed lyrics into .m4a tags")
    args = ap.parse_args()
    shard, shards = map(int, args.shard.split("/"))

    done = failed = 0
    for path in pending(find_audio(args.paths), shard, shards):
        try:
            process(path, args.embed)
            done += 1
        except Exception as e:
            failed += 1
            log(f"[FAIL] {path}: {e}")
            open(os.path.splitext(path)[0] + ".vtt.failed", "w").write(str(e))
        if args.limit and done + failed >= args.limit:
            break
    log(f"[done] captioned={done} failed={failed}")


def pending(audio, shard, shards):
    for path in audio:
        stem = os.path.splitext(path)[0]
        if zlib.crc32(path.encode()) % shards != shard or os.path.exists(stem + ".vtt"):
            continue
        marker = stem + ".vtt.failed"
        if os.path.exists(marker) and time.time() - os.path.getmtime(marker) < RETRY_FAILED_SECS:
            continue
        yield path


def process(path, embed):
    import mlx_whisper
    import mutagen

    t0 = time.time()
    # condition_on_previous_text=False: stops one misheard line from cascading into a
    # hallucinated loop for the rest of the episode.
    r = mlx_whisper.transcribe(path, path_or_hf_repo=MODEL, language=LANG,
                               condition_on_previous_text=False, verbose=None)
    segs = [{k: s[k] for k in ("start", "end", "text")} for s in r["segments"]]
    duration = mutagen.File(path).info.length
    cues = clamp_ends([c for s in segs for c in split_segment(s)], duration)
    lrc_path = write_sidecars(path, cues, duration, LANG)
    if embed and path.endswith(".m4a"):
        from mutagen.mp4 import MP4

        tags = MP4(path)
        tags["\xa9lyr"] = open(lrc_path, encoding="utf-8").read()
        tags.save()
    log(f"[asr] {path} {duration / 60:.0f}min in {time.time() - t0:.0f}s, {len(cues)} cues")


def split_segment(seg):
    """Whisper segments run long; split at punctuation near an even share of the text,
    spreading the segment's time across pieces by character count."""
    text, start, end = seg["text"].strip(), seg["start"], seg["end"]
    if not text:
        return []
    if len(text) <= MAX_CUE_CHARS and end - start <= MAX_CUE_SECS:
        return [{"text": text, "start": start, "end": end}]
    n = max(2, -(-len(text) // MAX_CUE_CHARS), int(-(-(end - start) // MAX_CUE_SECS)))
    target = len(text) / n
    pieces, buf = [], []
    for w in text.split():
        buf.append(w)
        joined = " ".join(buf)
        if len(joined) >= target and (w[-1] in ",.;:?!" or len(joined) >= MAX_CUE_CHARS * 0.9):
            pieces.append(joined)
            buf = []
    if buf:
        pieces.append(" ".join(buf))
    cues, t, per_char = [], start, (end - start) / max(1, sum(len(p) for p in pieces))
    for p in pieces:
        cues.append({"text": p, "start": t, "end": t + len(p) * per_char})
        t = cues[-1]["end"]
    return cues


if __name__ == "__main__":
    main()
