#!/usr/bin/env python3
"""Validate the M11 label sets and optionally render separate synthetic Mac audio tracks."""
import argparse
from array import array
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parent
RATE = 24_000


def read_split(name, expected_count):
    rows = [json.loads(line) for line in (ROOT / (name + ".jsonl")).read_text().splitlines()]
    if len(rows) != expected_count:
        raise ValueError(f"{name}: expected {expected_count} turns, found {len(rows)}")
    positions = Counter()
    for row in rows:
        positions[row["session"]] += 1
        if not row["session"].startswith(name + "-") or row["turn"] != positions[row["session"]]:
            raise ValueError(f"{name}: invalid session or turn number")
        if row.get("reference", 0) >= row["turn"] or not row["text"].strip():
            raise ValueError(f"{name}: invalid reference or text")
        if row["role"] not in {"interviewer", "candidate", "unknown"} or row["expected"] not in {"wait", "ignore", "accept"}:
            raise ValueError(f"{name}: invalid role or expectation")
        if row["role"] != "interviewer" and row["expected"] != "ignore":
            raise ValueError(f"{name}: only interviewer turns can request an answer")
    return rows


def clip(row, voice, temp):
    text_file, aiff, wav = [temp / name for name in ("clip.txt", "clip.aiff", "clip.wav")]
    text_file.write_text(row["text"])
    subprocess.run(["/usr/bin/say", "-v", voice, "-f", str(text_file), "-o", str(aiff)], check=True)
    subprocess.run(
        ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1", str(aiff), str(wav)],
        check=True,
    )
    with wave.open(str(wav), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, RATE):
            raise ValueError("Expected 24 kHz mono PCM16")
        samples = array("h", audio.readframes(audio.getnframes()))
    return samples


def render(rows, destination, name):
    voices = {"interviewer": "Samantha", "candidate": "Daniel", "unknown": "Kathy"}
    if name == "development":
        voices = {"interviewer": "Daniel", "candidate": "Kathy", "unknown": "Samantha"}
    grouped = {}
    for row in rows:
        grouped.setdefault(row["session"], []).append(row)
    with tempfile.TemporaryDirectory() as scratch:
        temp = Path(scratch)
        for session, turns in grouped.items():
            tracks = {role: array("h") for role in voices}
            position = RATE // 2
            marks = []
            for row in turns:
                samples = clip(row, voices[row["role"]], temp)
                start = position
                if marks and "overlap_previous_ms" in row:
                    start = marks[-1]["clip_end_sample"] - row["overlap_previous_ms"] * RATE // 1_000
                end = start + len(samples)
                track = tracks[row["role"]]
                track.extend(array("h", [0]) * max(0, end - len(track)))
                track[start:end] = samples
                marks.append({"turn": row["turn"], "role": row["role"],
                              "clip_start_sample": start, "clip_end_sample": end})
                position = max(position, end) + row.get("gap_ms", 550) * RATE // 1_000
            for role, track in tracks.items():
                track.extend(array("h", [0]) * (position - len(track)))
                (destination / f"{session}-{role}.pcm").write_bytes(track.tobytes())
            (destination / f"{session}-clip-marks.json").write_text(json.dumps(marks, indent=2) + "\n")


def normalize(text):
    return " ".join(re.findall(r"\w+", text.casefold()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", choices=("development", "held-out", "both", "qualification"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    sets = {name: read_split(name, count) for name, count in
            [("development", 200), ("held-out", 100), ("qualification", 100)]}
    seen = set()
    for name, rows in sets.items():
        normalized = {normalize(row["text"]) for row in rows}
        if seen & normalized:
            raise ValueError(f"{name}: text overlaps an earlier split")
        seen.update(normalized)
    for name, rows in sets.items():
        print(name, len(rows), dict(Counter(row["expected"] for row in rows)), flush=True)
    if args.render:
        if args.output is None:
            parser.error("--render requires --output")
        args.output.mkdir(parents=True, exist_ok=True)
        for name, rows in sets.items():
            if args.render == name or (args.render == "both" and name != "qualification"):
                render(rows, args.output, name)


if __name__ == "__main__":
    main()
