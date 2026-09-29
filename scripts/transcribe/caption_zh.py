#!/usr/bin/env python3
"""Caption Mandarin audio locally: FunASR Paraformer-zh + FSMN-VAD + CT-Punc, hotword biased.

Writes <audio>.vtt and <audio>.lrc beside each file. Raw sentence timestamps are kept in
WORK_DIR so the formats can be rebuilt (--rebuild) without re-running ASR.

Resumable at two levels: audio that already has a .vtt is skipped, and within a file each
~20min window is checkpointed, so a restart resumes at the next window.

The MPS allocator never returns the pool it grows during inference (~3.7GB per window,
unaffected by batch size), so a long-lived worker inevitably OOMs. Instead the worker
stops once the pool would exceed --mem-ceiling-gb and exits 75; run_until_done.sh
restarts it until it exits 0.

Usage:
  scripts/transcribe/run_until_done.sh caption_zh.py PATH...
  venv/bin/python scripts/transcribe/caption_zh.py PATH... [--limit N] [--device mps|cpu]
      [--mem-ceiling-gb N] [--hotwords FILE] [--force] [--rebuild]
"""
import argparse
import datetime
import gc
import hashlib
import json
import os
import subprocess
import sys
import time

from cues import clamp_ends, find_audio, write_sidecars

HERE = os.path.dirname(os.path.abspath(__file__))
HOTWORD_FILE = os.path.join(HERE, "hotwords_zh.txt")
LANG = "zh-CN"
WORK_DIR = os.path.expanduser("~/.cache/ear-to-listen-transcribe")
WAV_CACHE = os.path.join(WORK_DIR, "wav")
MODEL_CACHE = os.path.expanduser("~/llm_models")

EXIT_MORE_WORK = 75
WINDOW_SECS = 1200.0
WINDOW_SEARCH = 45.0
MAX_CUE_CHARS = 28
MAX_CUE_SECS = 8.0
MIN_CUE_SECS = 1.0
SPLIT_PUNCT = "，,、；;"
END_PUNCT = "。？！?!"


def log(msg):
    print(f"{datetime.datetime.now():%m-%d %H:%M:%S} {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--device", default="mps", choices=["mps", "cpu"])
    ap.add_argument("--mem-ceiling-gb", type=float, default=12.0,
                    help="restart before the pool would exceed this; ~12 gives a 10GB peak")
    ap.add_argument("--max-audio-secs", type=float, default=14400.0,
                    help="fallback stop for --device cpu, which does not leak")
    ap.add_argument("--hotwords", default=HOTWORD_FILE)
    ap.add_argument("--force", action="store_true", help="re-run ASR even if captions exist")
    ap.add_argument("--rebuild", action="store_true", help="rewrite captions from saved ASR, no ASR")
    args = ap.parse_args()

    sweep_wav_cache()
    audio = find_audio(args.paths)
    todo = [a for a in audio if args.force or args.rebuild or not os.path.exists(os.path.splitext(a)[0] + ".vtt")]
    skipped = len(audio) - len(todo)
    if args.limit:
        todo = todo[: args.limit]
    log(f"{len(audio)} audio files; {skipped} already captioned; {len(todo)} to do")

    model = None
    done = failed = 0
    budget = Budget(args.max_audio_secs, args.mem_ceiling_gb)
    t_start = time.time()

    for i, path in enumerate(todo, 1):
        log(f"[{i}/{len(todo)}] {path}")
        if args.rebuild and not os.path.isfile(work_path(path, "asr.json")):
            log("      no saved ASR to rebuild from; skipped")
            continue
        if model is None and not args.rebuild:
            log(f"      loading model on {args.device} ...")
            model = build_model(args.device)
            budget.baseline()
        t0 = time.time()
        try:
            duration, ncues = process(model, path, args, budget)
            done += 1
            el = time.time() - t0
            log(f"      {ncues} cues, {duration / 60:.0f}min audio in {el:.0f}s (rtf {el / duration:.3f}) "
                f"| {done} ok / {failed} fail / {len(todo) - i} left "
                f"| eta {(time.time() - t_start) / i * (len(todo) - i) / 60:.0f}min")
        except BudgetReached as e:
            log(f"      checkpointed ({e}); restarting worker to reclaim memory")
            sys.exit(EXIT_MORE_WORK)
        except Exception as e:
            failed += 1
            log(f"      [FAIL] {type(e).__name__}: {e}")
            if "out of memory" in str(e):
                log("      OOM: pool is unrecoverable in-process, restarting worker")
                sys.exit(EXIT_MORE_WORK)
        finally:
            release_memory()

        if model is not None and budget.exhausted():
            log(f"      pool {budget.pool_gb():.1f}GB; restarting worker")
            sys.exit(EXIT_MORE_WORK)

    log(f"finished: done={done} skipped={skipped} failed={failed} wall={(time.time() - t_start) / 60:.0f}min")
    sys.exit(1 if failed else 0)


def process(model, path, args, budget):
    json_path = work_path(path, "asr.json")
    partial_path = work_path(path, "asr.partial.json")

    if os.path.isfile(json_path) and not args.force:
        saved = json.load(open(json_path, encoding="utf-8"))
        duration, sentences = saved["duration"], saved["sentences"]
        log("      reusing saved ASR")
    else:
        duration = audio_duration(path)
        wav_path = cached_wav(path)
        if not os.path.isfile(wav_path):
            decode_to_wav(path, wav_path + ".part")
            os.replace(wav_path + ".part", wav_path)
        sentences = transcribe(model, wav_path, duration, partial_path, budget, args.hotwords)
        json.dump({"source": path, "duration": duration, "sentences": sentences},
                  open(json_path, "w", encoding="utf-8"), ensure_ascii=False)
        for stale in (partial_path, wav_path):
            os.path.exists(stale) and os.remove(stale)

    cues = build_cues(sentences, duration)
    write_sidecars(path, cues, duration, LANG)
    return duration, len(cues)


def build_model(device):
    os.environ["MODELSCOPE_CACHE"] = os.path.join(MODEL_CACHE, "modelscope")
    os.environ["HF_HOME"] = os.path.join(MODEL_CACHE, "huggingface")
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    import logging

    logging.getLogger().setLevel(logging.ERROR)
    from funasr import AutoModel

    return AutoModel(
        model="paraformer-zh",
        vad_model="fsmn-vad",
        punc_model="ct-punc",
        device=device,
        disable_update=True,
        disable_pbar=True,
        disable_log=True,
        vad_kwargs={"max_single_segment_time": 20000},
    )


def work_path(audio_path, suffix):
    os.makedirs(WORK_DIR, exist_ok=True)
    key = hashlib.sha1(os.path.abspath(audio_path).encode()).hexdigest()[:16]
    return os.path.join(WORK_DIR, f"{key}.{suffix}")


def cached_wav(audio_path):
    """A worker usually restarts mid-file; without this the audio is re-decoded each time."""
    os.makedirs(WAV_CACHE, exist_ok=True)
    return os.path.join(WAV_CACHE, hashlib.sha1(os.path.abspath(audio_path).encode()).hexdigest() + ".wav")


def sweep_wav_cache(max_age_hours=12):
    if not os.path.isdir(WAV_CACHE):
        return
    cutoff = time.time() - max_age_hours * 3600
    for name in os.listdir(WAV_CACHE):
        path = os.path.join(WAV_CACHE, name)
        if os.path.getmtime(path) < cutoff:
            os.remove(path)


def decode_to_wav(src, wav_path):
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                    "-ar", "16000", "-ac", "1", "-f", "wav", wav_path], check=True)


def audio_duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True, check=True)
    return float(r.stdout.strip())


def window_cuts(wav_path, duration):
    """Cut points near each WINDOW_SECS mark, snapped to the quietest spot nearby.

    Long episodes (some run 150min) exhaust MPS memory in a single pass, so they are
    transcribed in windows. Snapping to silence keeps cuts out of the middle of a word.
    """
    import numpy as np
    import soundfile as sf

    cuts = [0.0]
    t = WINDOW_SECS
    while duration - t > WINDOW_SECS / 2:
        lo, hi = max(t - WINDOW_SEARCH, cuts[-1] + 30.0), min(t + WINDOW_SEARCH, duration)
        try:
            audio, sr = sf.read(wav_path, start=int(lo * 16000), stop=int(hi * 16000), dtype="float32")
            hop = sr // 10
            frames = audio[: len(audio) // hop * hop].reshape(-1, hop)
            quietest = int(np.argmin(np.abs(frames).mean(axis=1)))
            cuts.append(lo + (quietest + 0.5) * hop / sr)
        except Exception:
            cuts.append(t)
        t = cuts[-1] + WINDOW_SECS
    cuts.append(duration)
    return cuts


class Budget:
    """Stops the worker before the MPS pool gets big enough to push the machine into swap.

    Pool size is the real constraint, not audio length, so it is polled directly; the
    audio limit is only a fallback for --device cpu, which does not leak.
    """

    def __init__(self, limit_secs, ceiling_gb):
        self.limit, self.ceiling, self.spent = limit_secs, ceiling_gb, 0.0
        self.prev = 0.0
        self.step = 0.0

    def baseline(self):
        """Call once the model is resident; before that the pool reads 0 and the first
        window's growth would wrongly include the model's own footprint."""
        self.prev = self.pool_gb()

    def spend(self, secs):
        self.spent += secs

    def note_window(self):
        """Track per-window growth so the ceiling is a peak, not a floor it overshoots."""
        now = self.pool_gb()
        self.step = max(self.step, now - self.prev)
        self.prev = now

    def pool_gb(self):
        import torch

        if hasattr(torch, "mps") and torch.backends.mps.is_available():
            return torch.mps.driver_allocated_memory() / 2**30
        return 0.0

    def exhausted(self):
        return self.pool_gb() + max(self.step, 0.5) >= self.ceiling or self.spent >= self.limit


class BudgetReached(Exception):
    """Raised to end the worker cleanly so a fresh one can reclaim the MPS pool."""


def transcribe(model, wav_path, duration, partial_path, budget, hotwords):
    kwargs = {"batch_size_s": 200, "sentence_timestamp": True}
    if hotwords and os.path.isfile(hotwords):
        kwargs["hotword"] = hotwords

    cuts = window_cuts(wav_path, duration)
    sentences, first = [], 0
    if os.path.isfile(partial_path):
        saved = json.load(open(partial_path, encoding="utf-8"))
        if saved.get("cuts") == cuts:
            sentences, first = saved["sentences"], saved["done"]
            log(f"      resuming at window {first + 1}/{len(cuts) - 1}")

    for i, (start, end) in enumerate(zip(cuts, cuts[1:])):
        if i < first or end - start < 1.0:
            continue
        if budget.exhausted():
            json.dump({"cuts": cuts, "done": i, "sentences": sentences},
                      open(partial_path, "w", encoding="utf-8"), ensure_ascii=False)
            raise BudgetReached(f"window {i + 1}/{len(cuts) - 1}, pool {budget.pool_gb():.1f}GB")
        chunk = wav_path + f".{int(start)}.wav"
        subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", f"{start:.3f}",
                        "-t", f"{end - start:.3f}", "-i", wav_path, "-c", "copy", chunk], check=True)
        try:
            res = model.generate(input=chunk, **kwargs)
            offset = int(start * 1000)
            for sent in res[0].get("sentence_info") or []:
                sent["start"] += offset
                sent["end"] += offset
                sent["timestamp"] = [[a + offset, b + offset] for a, b in sent.get("timestamp") or []]
                sentences.append(sent)
            del res
        finally:
            os.path.exists(chunk) and os.remove(chunk)
            release_memory()
        budget.spend(end - start)
        budget.note_window()
        json.dump({"cuts": cuts, "done": i + 1, "sentences": sentences},
                  open(partial_path, "w", encoding="utf-8"), ensure_ascii=False)
    return sentences


def release_memory():
    """MPS does not reclaim between files on its own; without this a long run OOMs."""
    gc.collect()
    import torch

    if hasattr(torch, "mps") and torch.backends.mps.is_available():
        torch.mps.empty_cache()


def split_sentence(sentence):
    """Break an over-long sentence at internal punctuation, keeping token timestamps."""
    text, stamps = sentence["text"], sentence.get("timestamp") or []
    if len(text) <= MAX_CUE_CHARS and (sentence["end"] - sentence["start"]) / 1000.0 <= MAX_CUE_SECS:
        return [sentence]

    pieces, buf, tok = [], "", 0
    piece_start = sentence["start"]
    for ch in text:
        buf += ch
        if ch not in SPLIT_PUNCT and ch not in END_PUNCT:
            tok += 1
        if ch in SPLIT_PUNCT and len(buf) >= MAX_CUE_CHARS // 2:
            end = stamps[tok - 1][1] if 0 < tok <= len(stamps) else sentence["end"]
            pieces.append({"text": buf, "start": piece_start, "end": end})
            buf, piece_start = "", end
    if buf.strip():
        pieces.append({"text": buf, "start": piece_start, "end": sentence["end"]})
    return pieces or [sentence]


def build_cues(sentences, duration):
    cues = []
    for s in sentences:
        for piece in split_sentence(s):
            text = piece["text"].strip()
            if text:
                cues.append({"text": text, "start": piece["start"] / 1000.0, "end": piece["end"] / 1000.0})

    merged = []
    for cue in cues:
        prev = merged[-1] if merged else None
        too_short = prev and (prev["end"] - prev["start"]) < MIN_CUE_SECS
        fits = prev and len(prev["text"]) + len(cue["text"]) <= MAX_CUE_CHARS
        if too_short and fits and cue["end"] - prev["start"] <= MAX_CUE_SECS:
            prev["text"] += cue["text"]
            prev["end"] = cue["end"]
        else:
            merged.append(cue)

    for i, cue in enumerate(merged):
        if cue["end"] <= cue["start"]:
            limit = merged[i + 1]["start"] if i + 1 < len(merged) else duration
            cue["end"] = min(cue["start"] + MIN_CUE_SECS, limit)
    return clamp_ends(merged, duration)


if __name__ == "__main__":
    main()
