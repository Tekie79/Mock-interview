# M11 synthetic interview corpus

`development.jsonl` has 200 labeled turns in 20 conversations. `held-out.jsonl` has 100 turns in 10 different conversations. The held-out text and recordings are reserved for the qualification run. The splits use different subjects, recording tracks and role/voice assignments.

Each row identifies the conversation, turn number, role, expected action and category. An optional reference points to an earlier turn within the same conversation. Continuations are judged as part of their logical question. Intentional repeats are separate turns. Duplicate event delivery is tested through the protocol fixtures.

Run `python3 Tests/Fixtures/m11/render.py` to validate the labels and cross-split text separation. On macOS with Samantha, Daniel and Kathy installed, render the audio outside the repository:

```sh
python3 Tests/Fixtures/m11/render.py --render both --output /tmp/mock-interview-m11-corpus
```

Each conversation yields three aligned raw mono PCM16 little-endian tracks at 24 kHz. A JSON file records the insertion sample positions for every clip. These positions support repeatable playback and overlap checks. Independently annotate the actual end of speech before using recordings for the product latency gate. Synthetic voices are one test condition. Human accent, room noise and microphone variation require separate coverage.

`zoom-qa.jsonl` adds a 12-turn synthetic transcript probe for interview questions interleaved with spoken answers and trailing agreement checks on one source. It is a supplemental fixture for the classifier boundary.

`qualification.jsonl` is the fresh M11 correction holdout. It was frozen before the correction and reserved for evaluation. It contains ten new scenarios and 100 turns with 40 accept, 50 ignore and 10 wait labels. Its SHA-256 is `5dd9e1f824c83b5a4299917db29d92d776ec25cf1f9095b26db013688d749f3f`. Run `python3 Tests/Fixtures/m11/render.py --render qualification --output <directory>` to generate its three PCM tracks and one label file per scenario. The renderer validates separation from both historical splits. Generated insertion boundaries require an independent speech-end audit for displayed-latency qualification.

`rc-holdout.jsonl` replaces `qualification.jsonl` as the independent synthetic split, because the earlier split informed the RC changes. Its 100 new cues span ten technical and behavioral conversations with 40 accept, 50 ignore and 10 wait labels. Its SHA-256 is `9b3ef25876d2c2cc79b44dceb7cd457df386f01e4410484b28f59a10428977c5`. Run `python3 -B Tests/Fixtures/m11/render.py --render rc-holdout --output <directory>`. On this Mac the renderer used six English voices and five speaking rates. The synthetic split supplements independently labeled human recordings and visually observed response timing.

## 90-minute remote playback

On a Mac with the three voices installed, build the tracks in a new scratch directory:

```sh
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/m11-endurance.XXXXXX")
python3 -B Tests/Fixtures/m11/render.py --render qualification --output "$run_dir/corpus"
python3 -B Tests/Fixtures/m11/endurance.py --corpus "$run_dir/corpus" --output "$run_dir/playback"
```

The builder creates two 24 kHz mono WAV files, each exactly 5,400 seconds. The ten nine-minute blocks each include the same ten scenes, a five-second lead-in and trailing silence. The remote track mixes interviewer and unknown voices. The separate candidate reference stays on the test Mac and can be played to the candidate microphone using a separate nearby device. The cue sheet has 1,000 sample-indexed entries with their block, role, expected action and source label hash.

Have a second participant join a private meeting and share only `remote.wav` as computer audio at normal speed. Start Mock Interview with the meeting process as question audio and an independent candidate microphone. Use headphones on the test Mac and align both files at the agreed start time during the lead-in. Time playback from that point and log any disconnect or restart. For a mixed-feed attribution run, select a diarization-capable transcription model and assign the voices in Transcript. Verify that each source reaches the workspace before beginning the timed run. Keep synthetic data and any explicitly saved test session local.

Use cue times for matching turns, then independently mark acoustic speech ends for display latency. Score blocks as sequential repeated load, with separate counts for intentional repeats and duplicate cards. Record submitted audio, provider usage, queue overflows and source reconnects. Confirm sufficient room in the approved US$10 total before starting the dual-source run.
