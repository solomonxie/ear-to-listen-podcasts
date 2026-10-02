#!/usr/bin/env python3
"""Save YouTube videos' subtitles as .vtt files the app's transcript Load button reads.

Runs on a Mac, never in the app. Hand-made subtitles when a video has them, YouTube's
automatic ones otherwise — cleaned of the rolling repeats auto-captions are made of.

    venv/bin/python scripts/youtube/subtitles.py URL [URL ...] [--langs en,zh-Hans] [--out DIR]

A URL can be a video or a whole playlist. Files go to the app's iCloud Drive folder
(Files › iCloud Drive › Ear to Listen › Subtitles) when this Mac has it, else ./subtitles.
"""
import argparse
import re
from pathlib import Path

ICLOUD_FOLDER = Path.home() / "Library/Mobile Documents/iCloud~com~solomonxie~eartolisten/Documents"
DEFAULT_LANGS = "en,zh-Hans,zh-Hant,zh"
TIMING = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3}) --> (\d{2}:\d{2}:\d{2}\.\d{3})")
INLINE_TAG = re.compile(r"<[^>]+>")


def default_out() -> Path:
    return ICLOUD_FOLDER / "Subtitles" if ICLOUD_FOLDER.is_dir() else Path("subtitles")


def seconds(stamp: str) -> float:
    h, m, s = stamp.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def cues(vtt: str) -> list[tuple[str, str, list[str]]]:
    """(start, end, lines) for every cue in a WebVTT file."""
    # Split on truly empty lines only: auto-captions pad cues with a line holding one space.
    found = []
    for block in vtt.replace("\r\n", "\n").split("\n\n"):
        lines = block.split("\n")
        for i, line in enumerate(lines):
            match = TIMING.match(line)
            if match:
                found.append((match[1], match[2], lines[i + 1:]))
                break
    return found


def clean_auto_captions(vtt: str) -> str:
    """One cue per spoken line, from YouTube's rolling auto-captions.

    Each auto-caption cue repeats the line before it above the new one, word-timing tags
    inside, then a 10 ms cue holds the finished line. Kept: the new line of each real cue.
    A file without word tags is hand-made and comes back as it was.
    """
    if "<c>" not in vtt:
        return vtt
    out = ["WEBVTT", ""]
    last = None
    for start, end, lines in cues(vtt):
        if seconds(end) - seconds(start) < 0.05:
            continue
        text = [INLINE_TAG.sub("", line).strip() for line in lines]
        text = [line for line in text if line]
        if not text or text[-1] == last:
            continue
        last = text[-1]
        out += [f"{start} --> {end}", last, ""]
    return "\n".join(out)


def download(urls: list[str], langs: list[str], out: Path) -> list[Path]:
    import yt_dlp

    out.mkdir(parents=True, exist_ok=True)
    before = set(out.glob("*.vtt"))
    options = {
        "skip_download": True,
        "writesubtitles": True,
        # Only where a language has no hand-made track.
        "writeautomaticsub": True,
        "subtitleslangs": langs,
        "subtitlesformat": "vtt",
        "outtmpl": str(out / "%(title)s [%(id)s].%(ext)s"),
        "ignoreerrors": True,
    }
    with yt_dlp.YoutubeDL(options) as ydl:
        ydl.download(urls)
    written = sorted(set(out.glob("*.vtt")) - before)
    for path in written:
        path.write_text(clean_auto_captions(path.read_text(encoding="utf-8")), encoding="utf-8")
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("urls", nargs="+", help="video or playlist links")
    parser.add_argument("--langs", default=DEFAULT_LANGS, help=f"comma-separated (default {DEFAULT_LANGS})")
    parser.add_argument("--out", type=Path, default=None, help="folder (default: the app's iCloud folder)")
    args = parser.parse_args()
    out = args.out or default_out()
    written = download(args.urls, [lang.strip() for lang in args.langs.split(",") if lang.strip()], out)
    for path in written:
        print(path)
    print(f"{len(written)} file(s) in {out}" if written else "No subtitles found.")


if __name__ == "__main__":
    main()


# --- tests: venv/bin/pytest scripts/youtube/subtitles.py ---

FIXTURES = Path(__file__).parent / "fixtures"


def test_auto_captions_become_one_cue_per_line():
    cleaned = clean_auto_captions((FIXTURES / "auto-captions.en.vtt").read_text(encoding="utf-8"))
    texts = [lines[0] for _, _, lines in cues(cleaned)]
    assert texts[:4] == ["Hear that?", "That's nothing.", "Which is what I, as a speaker at today's", "conference,"]
    assert len(texts) == len(set(texts))
    assert "<c>" not in cleaned


def test_cleaned_cues_keep_their_times():
    cleaned = clean_auto_captions((FIXTURES / "auto-captions.en.vtt").read_text(encoding="utf-8"))
    assert cues(cleaned)[0][:2] == ("00:00:19.560", "00:00:21.950")


def test_hand_made_subtitles_are_left_alone():
    original = (FIXTURES / "manual-captions.en.vtt").read_text(encoding="utf-8")
    assert clean_auto_captions(original) == original
