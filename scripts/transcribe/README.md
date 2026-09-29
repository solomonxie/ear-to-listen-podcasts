# Desktop Transcription & AI Polish

Batch captioning and LLM clean-up for audio in your library. Runs on an Apple Silicon Mac,
not in the app. Ported from the retired `sermon-voices` project, keeping its tuned settings.

The output uses the app's sidecar convention: `ep1.mp3` gets `ep1.vtt` + `ep1.lrc` beside it,
so the app imports it the next time it syncs that folder or bucket.

| Script | Does |
|---|---|
| `caption_zh.py` | Mandarin: FunASR Paraformer-zh + FSMN-VAD + CT-Punc, biased with `hotwords_zh.txt` |
| `caption_en.py` | English: MLX Whisper `distil-whisper-large-v3` |
| `run_until_done.sh` | Supervisor: restarts a worker on exit 75 until the batch is done |
| `polish.py` | LLM clean-up of a transcript into `<audio>.polished.md` |
| `build_hotwords.py` | Rebuilds `hotwords_zh.txt` |
| `bible_cuv.tsv.gz` | CUV Bible text, 31,101 verses, for `polish.py --bible` |

## Run

```sh
python3 -m venv venv && venv/bin/pip install -r scripts/transcribe/requirements.txt
scripts/transcribe/run_until_done.sh caption_zh.py ~/Podcasts/show   # tail -f /tmp/ear-to-listen-transcribe/run.log
venv/bin/python scripts/transcribe/caption_en.py ~/Podcasts/show [--shard 0/2]
venv/bin/python scripts/transcribe/polish.py ~/Podcasts/show/ep1.mp3 --bible --context "Speaker: …; Series: …"
```

Models are cached under `~/llm_models/`. The ASR checkpoints go in `~/.cache/ear-to-listen-transcribe/`. Polish defaults
to local Ollama `qwen3:4b-instruct-2507-q8_0`. For any OpenAI-compatible API, pass
`--base-url` + `--model` and set `OPENAI_API_KEY`.

## Tuned settings (and why)

**Mandarin ASR**
- Paraformer-zh + `fsmn-vad` (`max_single_segment_time` 20s) + `ct-punc`, `batch_size_s` 200, `sentence_timestamp`.
- Hotwords were the main accuracy lever on domain audio. For another domain, write your own list and pass `--hotwords FILE`.
- **Long audio in ~20 min windows**, each cut snapped to the quietest 0.1 s frame within ±45 s so no cut lands mid-word. Timestamps are shifted back to absolute time.
- **The MPS pool never shrinks** (~3.7 GB per window). A long-lived worker always OOMs. So `Budget` polls `torch.mps.driver_allocated_memory()` and tracks the largest per-window growth. The worker exits 75 before `pool + growth ≥ --mem-ceiling-gb` (12). The supervisor restarts it with a fresh pool. That is how multi-day, thousand-episode runs finished unattended.
- **Two-level resume**: files that already have a `.vtt` are skipped, and each window is checkpointed. The decoded 16 kHz WAV is cached, so a restart doesn't decode again.
- **Cues**: ≤28 chars, ≤8 s. Split at `，、；` using per-token timestamps, and merge cues shorter than 1 s back in when they fit.
- Raw sentences are kept, so `--rebuild` can redo the cue format without running ASR again.

**English ASR**
- `condition_on_previous_text=False` keeps one misheard line from snowballing into a hallucinated loop.
- Cues: ≤84 chars, ≤7 s. Split at punctuation and share out time by character count.
- A failed file is retried only after 2 h (`.vtt.failed` marker). `--shard i/n` runs parallel workers.

**Polish** (per ~60 s chunk, temperature 0, JSON mode, `<think>` stripped)
1. *merge* (`--also`): ROVER by LLM. Different engines err in different places.
2. *pick*: list ASR errors, fillers, repetitions, logic gaps, paragraphing.
3. *refine*: keep the original wording (no paraphrase), fix the listed errors, remove fillers, add nothing.
4. *judge*: score the change from 0 to 1. Repeat steps 2–4 until the score is ≥ 0.99 or no errors remain, at most 3 rounds.
- `--bible`: the LLM only *names* the references. The verse text comes from `bible_cuv.tsv.gz`, so a misremembered quote never becomes the "correction". The verses are in traditional characters.
- Per-show rules: put a `transcript.md` in the audio's folder or its parent, or pass `--instructions`.
- Timed captions are left untouched. Polishing merges sentences, so its output has no honest timestamps.

## Tried and dropped

- Whisper **large-v3 on Chinese** hallucinates YouTube outros ("请不吝点赞 转发支持…"), so the project switched to large-v2. Keep this in mind if the app ever moves off `whisper-1`.
- qwen3-asr: memory leak. GLM-ASR-Nano: needs transformers 5 dev (a conflict). WhisperX: no MPS.
- Speaker diarization: added, then reverted.
- An 8-engine ensemble (SenseVoice, WhisperX, Paraformer, Fun-ASR-Nano, OpenAI, Groq, Deepgram, HF) merged per chunk. The single-engine caption pipeline replaced it. Only the merge step is kept, as `--also`.
- OpenAI for polishing: ~$0.50 per sermon file, which led back to a local LLM.
- Unmerged experiment (`improve_transcript_20260225`): the LLM flags bad timeframes, those get re-transcribed with several engines, and the fixes are woven back in. Not ported.
- Pre-ASR ffmpeg clean-up `highpass=f=200,lowpass=f=3000,afftdn,loudnorm` was used only in the ensemble path.
