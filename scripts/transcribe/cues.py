"""Caption formats and audio discovery shared by caption_zh.py and caption_en.py.

Output follows the app's sidecar convention: same basename as the audio, .vtt canonical,
.lrc a courtesy copy for lyrics-aware players.
"""
import os

AUDIO_EXTS = (".mp3", ".m4a", ".wav", ".aac", ".ogg", ".opus", ".flac")


def find_audio(paths):
    """Files as given, directories walked; sorted so reruns go in the same order."""
    found = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                found += [os.path.join(root, n) for n in names if n.lower().endswith(AUDIO_EXTS)]
        elif p.lower().endswith(AUDIO_EXTS):
            found.append(p)
    return sorted(found)


def vtt_time(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{s:06.3f}"


def lrc_time(t):
    m, s = divmod(max(t, 0), 60)
    return f"[{int(m):02d}:{s:05.2f}]"


def clamp_ends(cues, duration):
    """No cue runs into the next one, and none is shorter than 0.2s."""
    for i, c in enumerate(cues):
        limit = cues[i + 1]["start"] if i + 1 < len(cues) else duration
        c["end"] = min(max(c["end"], c["start"] + 0.2), max(limit, c["start"] + 0.2))
    return cues


def render_vtt(cues, title, lang):
    out = ["WEBVTT", "", f"NOTE {title} [{lang}]", ""]
    for i, c in enumerate(cues, 1):
        out += [str(i), f"{vtt_time(c['start'])} --> {vtt_time(c['end'])}", c["text"], ""]
    return "\n".join(out)


def render_lrc(cues, title, duration):
    m, s = divmod(duration, 60)
    out = [f"[ti:{title}]", f"[length:{int(m):02d}:{int(s):02d}]", ""]
    out += [f"{lrc_time(c['start'])}{c['text']}" for c in cues]
    out.append(lrc_time(duration))
    return "\n".join(out) + "\n"


def write_atomic(path, text):
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(path + ".tmp", path)


def write_sidecars(audio_path, cues, duration, lang):
    stem = os.path.splitext(audio_path)[0]
    title = os.path.basename(stem)
    write_atomic(stem + ".vtt", render_vtt(cues, title, lang))
    write_atomic(stem + ".lrc", render_lrc(cues, title, duration))
    return stem + ".lrc"
