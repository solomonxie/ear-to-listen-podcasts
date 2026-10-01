"""Speaks every episode in demo-library.json with macOS `say`, one voice per speaker.

Writes Audio/demo-<episode>.m4a (HE-AAC, mono) and demo-timings.json — each line's
start/end and each episode's duration and size — so the seeded transcripts line up
with the audio exactly.

    venv/bin/python DemoData/make-audio.py
"""

import json
import os
import subprocess
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
RATE = 24000
LEAD_IN = 0.6
SAME_SPEAKER_GAP = 0.35
SPEAKER_CHANGE_GAP = 0.65


def speak(text, voice, rate, path):
    subprocess.run(
        ["say", "-v", voice, "-r", str(rate), "-o", path, f"--data-format=LEI16@{RATE}", text],
        check=True,
    )
    with wave.open(path, "rb") as w:
        return w.readframes(w.getnframes())


def silence(seconds):
    return b"\x00\x00" * int(RATE * seconds)


def main():
    with open(os.path.join(HERE, "demo-library.json"), encoding="utf-8") as f:
        library = json.load(f)
    speakers = {s["key"]: s for s in library["speakers"]}
    audio_dir = os.path.join(HERE, "Audio")
    os.makedirs(audio_dir, exist_ok=True)
    timings = {}

    with tempfile.TemporaryDirectory() as tmp:
        for album in library["albums"]:
            for episode in album["episodes"]:
                frames = bytearray(silence(LEAD_IN))
                lines = []
                previous = None
                for index, (speaker_key, text) in enumerate(episode["lines"]):
                    if previous is not None:
                        frames += silence(SAME_SPEAKER_GAP if speaker_key == previous else SPEAKER_CHANGE_GAP)
                    speaker = speakers[speaker_key]
                    start = len(frames) / 2 / RATE
                    frames += speak(text, speaker["voice"], speaker.get("rate", 175), os.path.join(tmp, f"{index}.wav"))
                    lines.append({"start": round(start, 2), "end": round(len(frames) / 2 / RATE, 2)})
                    previous = speaker_key
                frames += silence(1.0)

                wav_path = os.path.join(tmp, f"{episode['key']}.wav")
                with wave.open(wav_path, "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(RATE)
                    w.writeframes(bytes(frames))
                m4a_path = os.path.join(audio_dir, f"demo-{episode['key']}.m4a")
                subprocess.run(["afconvert", "-f", "m4af", "-d", "aach", "-b", "16000", wav_path, m4a_path], check=True)

                timings[episode["key"]] = {
                    "durationMs": int(len(frames) / 2 / RATE * 1000),
                    "sizeBytes": os.path.getsize(m4a_path),
                    "lines": lines,
                }
                print(f"{episode['key']}: {timings[episode['key']]['durationMs'] / 1000:.0f}s")

    with open(os.path.join(HERE, "demo-timings.json"), "w", encoding="utf-8") as f:
        json.dump(timings, f, indent=1)


if __name__ == "__main__":
    main()
