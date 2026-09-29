#!/usr/bin/env python3
"""Polish a raw ASR transcript into readable text with an LLM.

Per ~1min chunk of the transcript:
  0. merge    (only with --also) reconcile several ASR transcripts of the same audio
  1. pick     list ASR errors, fillers, repetitions, flow problems
  2. refine   rewrite with those errors + custom instructions + CUV verses as context
  3. judge    score how much changed; loop 1-3 until stable (score >= 0.99) or no
              errors left, max 3 rounds

Writes <audio>.polished.md (a basename no audio shares, so the app never reads it as a
sidecar). Timed captions are left untouched: polishing merges and reorders sentences, so
its output has no honest timestamps.

Any OpenAI-compatible endpoint works. Default is local Ollama; for OpenAI:
  --base-url https://api.openai.com/v1 --model gpt-4o-mini   (OPENAI_API_KEY in env)

Usage:
  venv/bin/python scripts/transcribe/polish.py EP.vtt [--also EP.whisper.vtt ...]
      [--context "Preacher: ...; Series: ..."] [--instructions FILE] [--bible] [--kind sermon]
"""
import argparse
import functools
import gzip
import json
import os
import re
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIBLE_TSV = os.path.join(HERE, "bible_cuv.tsv.gz")
DEFAULT_MODEL = "qwen3:4b-instruct-2507-q8_0"
DEFAULT_BASE_URL = "http://localhost:11434/v1"
CHUNK_SECS = 60.0
MAX_ROUNDS = 3
STABLE_SCORE = 0.99
INSTRUCTIONS_FILE = "transcript.md"
LOG_DIR = "/tmp/ear-to-listen-transcribe"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript", help=".vtt/.srt/.lrc/.txt, or the audio beside one")
    ap.add_argument("--also", nargs="*", default=[], help="other ASR transcripts of the same audio")
    ap.add_argument("--context", default="", help="who/what: speaker, show, topic, accent")
    ap.add_argument("--instructions", help=f"custom rules; default: {INSTRUCTIONS_FILE} in the folder or its parent")
    ap.add_argument("--bible", action="store_true", help="ground scripture quotes in the bundled CUV text")
    ap.add_argument("--kind", default="sermon", help="what the audio is, used in prompts")
    ap.add_argument("--model", default=os.getenv("POLISH_MODEL", DEFAULT_MODEL))
    ap.add_argument("--base-url", default=os.getenv("POLISH_BASE_URL", DEFAULT_BASE_URL))
    args = ap.parse_args()

    path = resolve_transcript(args.transcript)
    stem = os.path.splitext(path)[0]
    out_path = stem + ".polished.md"
    llm = Llm(args.model, args.base_url, os.path.join(LOG_DIR, os.path.basename(stem) + ".polish.log"))
    ctx = build_context(path, args)

    primary = read_cues(path)
    others = [read_cues(resolve_transcript(p)) for p in args.also]
    chunks = chunk(primary)
    paragraphs = []
    for i, (start, end, text) in enumerate(chunks, 1):
        t0 = time.time()
        print(f"[{i}/{len(chunks)}] {start / 60:.1f}-{end / 60:.1f}min", flush=True)
        if others:
            until = end if i < len(chunks) else float("inf")
            variants = {"primary": text} | {f"asr{n}": text_between(o, start, until) for n, o in enumerate(others, 1)}
            text = merge(llm, variants, ctx, args.kind)
        paragraphs.append(polish_chunk(llm, text, ctx, args))
        print(f"      {time.time() - t0:.0f}s", flush=True)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n\n".join(p for p in paragraphs if p.strip()) + "\n")
    print(f"wrote {out_path}")


def polish_chunk(llm, text, ctx, args):
    if len(text.strip()) < 2:
        return text
    bible = bible_verses(llm, text) if args.bible else ""
    refined = text
    for i in range(MAX_ROUNDS):
        errors = pick_errors(llm, refined, args.kind)
        if not errors.strip() and i > 0:
            break
        extra = f"""
            --- START CONTEXT ---
            {ctx}
            --- END CONTEXT ---
            --- START BIBLE REFERENCE (CUV) ---
            {bible}
            --- END BIBLE REFERENCE (CUV) ---
            --- START IDENTIFIED ERRORS ---
            {errors}
            --- END IDENTIFIED ERRORS ---
        """
        last = refined
        refined = refine(llm, refined, extra, args.kind, bool(bible))
        score, reason = judge(llm, refined, last, args.kind)
        print(f"      round {i + 1}: stable {score:.0%} ({reason})", flush=True)
        if score >= STABLE_SCORE:
            break
    return refined


def merge(llm, variants, ctx, kind):
    """ROVER by LLM: several ASR engines err in different places, so the union corrects most."""
    valid = {k: v for k, v in variants.items() if v.strip()}
    if len(valid) <= 1:
        return next(iter(valid.values()), "")
    listed = "\n".join(f"- {k}: {v}" for k, v in valid.items())
    prompt = f"""
    Please merge the following ASR transcriptions for a {kind} segment into a single, accurate version.

    CONTEXT:
    {ctx}

    TRANSCRIPTIONS:
    {listed}

    RULES:
    1. Analyze the transcriptions to identify the most likely correct words and phrases.
    2. Pay attention to context (speaker, scripture) to resolve discrepancies.
    3. Synthesize the best parts of each transcription. Do not just pick one.
    4. Return ONLY the merged and corrected text.
    5. If all inputs are noisy or nonsensical, return an empty string.

    Output JSON: {{"data": "merged text..."}}
    """
    return str(llm.ask(prompt).get("data") or "") or valid["primary"]


def pick_errors(llm, text, kind):
    prompt = f"""
    Analyze the {kind} transcript and identify issues for transforming it into a polished article/paper.

    PRIMARY GOAL:
    Find ASR errors, logical inconsistencies, and flow problems that hinder reading clarity. **Respect the original punctuations unless they are clearly incorrect ASR artifacts.**

    ERROR CATEGORIES:
    - ASR errors: homophones, typos, misheard names, places and terms.
    - Fillers/Stammers: "这个这个", "呃", "嗯", "啊", "那个那个", "um", "uh", "you know" (mark these for removal).
    - Logical Gaps: Phrasing that lacks context or seems disconnected from the surrounding text.
    - Punctuation/Paragraphing: Missing logical breaks or incorrect punctuation for a formal article.
    - Repetitions: Redundant phrases or stutters that should be streamlined.

    Transcript:
    {text}

    Output JSON: {{"data": "issue: suggestion;\\nissue: suggestion; ..."}}
    """
    return format_errors(llm.ask(prompt).get("data"))


def format_errors(data):
    """Models return the list as a string, a list of strings, or a list of dicts."""
    if not data:
        return ""
    if isinstance(data, str):
        return data
    if isinstance(data, list):
        return "\n".join(": ".join(str(v) for v in e.values()) if isinstance(e, dict) else str(e) for e in data)
    return str(data)


def refine(llm, text, extra, kind, with_bible):
    bible_rules = """
    2. CORRECT biblical terms/names to Chinese Union Version (CUV).
    3. Use the provided Bible verse reference to correct biblical terms/names/sentences.""" if with_bible else """
    2. CORRECT names and terms using the context.
    3. Keep quotations as spoken unless clearly misheard."""
    prompt = f"""
    Refine the {kind} transcript.
    PRIMARY RULES:
    1. PRESERVE ORIGINAL WORDING & STYLE. Do NOT paraphrase. Keep the original language.{bible_rules}
    4. Fix punctuation and obvious ASR errors, separate paragraphs based on context.
    5. Remove stammers and fillers (呃, 嗯, 那个, um, uh).
    6. Do NOT add any additional content.

    {extra}

    Original transcript:
    {text}

    Output JSON: {{"data": "..."}}
    """
    refined = llm.ask(prompt).get("data")
    return str(refined).strip() if refined and str(refined).strip() else text


def judge(llm, text, last_text, kind):
    prompt = f"""
    Compare the following two versions of a {kind} transcript.
    Evaluate if the refinement has stabilized (i.e., no more significant corrections are needed).

    Previous Version:
    {last_text}

    Current Version:
    {text}

    A score of 1.0 means the text is identical or only has trivial punctuation changes.
    A score below 0.9 means significant meaningful changes were still made.

    Return a JSON object:
    {{
        "score": 0.0-1.0,
        "reason": "Brief explanation of why the score was given"
    }}
    """
    data = llm.ask(prompt)
    try:
        score = float(data.get("score") or 0.0)
    except (TypeError, ValueError):
        score = 0.0
    return score, data.get("reason") or "No reason provided"


def bible_verses(llm, text):
    """The LLM only names the references; the verse text comes from bible_cuv.tsv.gz, so a
    misremembered quote can't be fed back in as the "correct" wording."""
    prompt = f"""
    从以下的讲道内容中，找出所有引用或暗示的圣经出处。

    讲道内容:
    {text}

    输出必须是如下格式的JSON对象:
    {{"data": [{{"book": "约翰福音", "chapter": 3, "verse": 16}}, ...]}}
    书名用和合本全称。只知道章不知道节时 verse 为 null。
    如果没有找到明确的经文，返回 {{"data": []}}。
    """
    refs = llm.ask(prompt).get("data") or []
    if not isinstance(refs, list):
        return ""
    bible, lines = load_bible(), []
    for r in refs[:8]:
        if not isinstance(r, dict) or not r.get("book") or not r.get("chapter"):
            continue
        chapter = bible.get((r["book"], int(r["chapter"])), {})
        verse = int(r["verse"]) if r.get("verse") else None
        picked = [v for v in chapter if verse is None or abs(v - verse) <= 1][:40]
        lines += [f'{r["book"]} {r["chapter"]}:{v} - "{chapter[v]}"' for v in picked]
    return "\n".join(lines)


@functools.cache
def load_bible():
    """{(book, chapter): {verse: text}} from the bundled CUV text (31k verses, ~0.2s)."""
    bible = {}
    with gzip.open(BIBLE_TSV, "rt", encoding="utf-8") as f:
        for line in f:
            book, chapter, verse, text = line.rstrip("\n").split("\t")
            bible.setdefault((book, int(chapter)), {})[int(verse)] = text
    return bible


def build_context(path, args):
    parts = [f"Title: {os.path.basename(os.path.splitext(path)[0])}"]
    if args.context:
        parts.append(args.context)
    instr = args.instructions or next(
        (p for p in (os.path.join(d, INSTRUCTIONS_FILE) for d in (os.path.dirname(path), os.path.dirname(os.path.dirname(path))))
         if os.path.isfile(p)), None)
    if instr and os.path.isfile(instr):
        parts.append("CUSTOM INSTRUCTIONS:\n" + open(instr, encoding="utf-8").read().strip())
    return "\n".join(parts)


class Llm:
    def __init__(self, model, base_url, log_path):
        from openai import OpenAI

        self.model, self.log_path = model, log_path
        self.client = OpenAI(base_url=base_url, api_key=os.getenv("OPENAI_API_KEY") or "ollama")

    def ask(self, prompt, retries=3):
        for attempt in range(retries):
            try:
                r = self.client.chat.completions.create(
                    model=self.model, temperature=0.0, response_format={"type": "json_object"},
                    messages=[{"role": "user", "content": prompt}])
                content = r.choices[0].message.content or ""
                break
            except Exception as e:
                if attempt == retries - 1:
                    raise
                print(f"      retry {attempt + 1}: {type(e).__name__}: {e}", flush=True)
                time.sleep(2.0 * 2**attempt)
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        match = re.search(r"\{.*\}", content, re.DOTALL)
        content = (match.group(0) if match else content).replace("“", '"').replace("”", '"')
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(f"\n{'=' * 50}\nPROMPT:\n{prompt}\n{'-' * 50}\nRESPONSE:\n{content}\n")
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            return {"data": content}


def resolve_transcript(path):
    if path.lower().endswith((".vtt", ".srt", ".lrc", ".txt")):
        return path
    stem = os.path.splitext(path)[0]
    for ext in (".vtt", ".srt", ".lrc", ".txt"):
        if os.path.exists(stem + ext):
            return stem + ext
    raise SystemExit(f"no transcript beside {path}")


TIME = r"(?:(\d+):)?(\d+):(\d+)[.,](\d+)"


def read_cues(path):
    """(start_secs, text) pairs; enough of VTT/SRT/LRC for chunking. TXT gets one cue."""
    raw = open(path, encoding="utf-8-sig").read().replace("\r\n", "\n")
    if path.lower().endswith(".txt"):
        return [(0.0, raw.strip())]
    cues = []
    if path.lower().endswith(".lrc"):
        for line in raw.splitlines():
            m = re.match(r"\[(\d+):(\d+(?:\.\d+)?)\](.*)", line)
            if m and m.group(3).strip():
                cues.append((int(m.group(1)) * 60 + float(m.group(2)), m.group(3).strip()))
        return cues
    for block in re.split(r"\n\s*\n", raw):
        lines = block.strip().splitlines()
        for i, line in enumerate(lines):
            m = re.match(TIME + r"\s*-->", line)
            if m:
                h, mnt, s, frac = m.groups()
                start = int(h or 0) * 3600 + int(mnt) * 60 + int(s) + float("0." + frac)
                text = re.sub(r"<[^>]+>", "", " ".join(lines[i + 1:])).strip()
                if text:
                    cues.append((start, text))
                break
    return cues


def joiner(a, b):
    """No space between two CJK characters, a space otherwise."""
    cjk = lambda c: "　" <= c <= "鿿" or "＀" <= c <= "￯"
    return "" if a and b and cjk(a[-1]) and cjk(b[0]) else " "


def join_text(texts):
    out = ""
    for t in texts:
        out += (joiner(out, t) if out else "") + t
    return out


def chunk(cues):
    """~CHUNK_SECS groups — about what a small local model can polish without drifting."""
    if not cues:
        return []
    groups, cur, start = [], [], cues[0][0]
    for t, text in cues:
        if cur and t - start >= CHUNK_SECS:
            groups.append((start, t, join_text(cur)))
            cur, start = [], t
        cur.append(text)
    groups.append((start, cues[-1][0], join_text(cur)))
    return groups


def text_between(cues, start, end):
    return join_text([text for t, text in cues if start <= t < end])


if __name__ == "__main__":
    main()
