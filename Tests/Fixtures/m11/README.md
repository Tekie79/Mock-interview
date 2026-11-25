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
