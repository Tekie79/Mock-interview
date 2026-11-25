#!/usr/bin/env python3
"""Assemble the rendered M11 qualification corpus into aligned 90-minute WAV files."""

import argparse
from array import array
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import sys
import wave

from render import RATE, ROOT, read_split

BLOCK_SECONDS = 9 * 60
BLOCK_COUNT = 10
LEAD_IN_SECONDS = 5


def read_pcm(path):
    samples = array("h")
    samples.frombytes(path.read_bytes())
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def pcm_bytes(samples):
    if sys.byteorder != "little":
        samples = array("h", samples)
        samples.byteswap()
    return samples.tobytes()


def assemble_block(corpus):
    frames = LEAD_IN_SECONDS * RATE
    silence = bytes(frames * 2)
    remote, candidate = bytearray(silence), bytearray(silence)
    sessions = defaultdict(list)
    for row in read_split("qualification", 100):
        sessions[row["session"]].append(row)
    cues = []
    for session, rows in sorted(sessions.items()):
        marks = json.loads((corpus / f"{session}-clip-marks.json").read_text())
        interviewer, reference, unknown = (
            read_pcm(corpus / f"{session}-{role}.pcm")
            for role in ("interviewer", "candidate", "unknown")
        )
        length = len(interviewer)
        if not length or len(reference) != length or len(unknown) != length or len(marks) != len(rows):
            raise ValueError(f"{session}: unaligned tracks or labels")
        for row, mark in zip(rows, marks):
            start, end = mark["clip_start_sample"], mark["clip_end_sample"]
            if row["role"] != mark["role"] or row["turn"] != mark["turn"] or not 0 <= start < end <= length:
                raise ValueError(f"{session}: invalid turn boundaries")
            cues.append({**mark, "scene": session, "expected": row["expected"],
                         "clip_start_sample": frames + start, "clip_end_sample": frames + end})
        combined = array("h", (max(-32768, min(32767, a + b)) for a, b in zip(interviewer, unknown)))
        remote.extend(pcm_bytes(combined))
        candidate.extend(pcm_bytes(reference))
        frames += length
    if frames > BLOCK_SECONDS * RATE:
        raise ValueError("The source corpus is longer than one nine-minute block")
    tail = bytes((BLOCK_SECONDS * RATE - frames) * 2)
    remote.extend(tail)
    candidate.extend(tail)
    return remote, candidate, cues


def write_track(path, block):
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, RATE, BLOCK_COUNT * BLOCK_SECONDS * RATE, "NONE", "not compressed"))
        for _ in range(BLOCK_COUNT):
            audio.writeframesraw(block)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, type=Path, help="directory with rendered qualification PCM")
    parser.add_argument("--output", required=True, type=Path, help="new directory for the WAVs and cue sheet")
    args = parser.parse_args()
    remote, candidate, cues = assemble_block(args.corpus)
    args.output.mkdir(parents=True)
    write_track(args.output / "remote.wav", remote)
    write_track(args.output / "candidate-reference.wav", candidate)
    turns = []
    for block in range(BLOCK_COUNT):
        offset = block * BLOCK_SECONDS * RATE
        for cue in cues:
            turns.append({**cue, "block": block + 1, "clip_start_sample": cue["clip_start_sample"] + offset,
                          "clip_end_sample": cue["clip_end_sample"] + offset})
    manifest = {"sample_rate": RATE, "duration_seconds": BLOCK_COUNT * BLOCK_SECONDS,
                "source_labels_sha256": hashlib.sha256((ROOT / "qualification.jsonl").read_bytes()).hexdigest(),
                "turns": turns}
    (args.output / "cues.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(turns)} cues, {manifest['duration_seconds']} seconds per track")


if __name__ == "__main__":
    main()
