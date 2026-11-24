# Implementation status

Baseline is a repository bootstrap only; no real application or provider integration. Status vocabulary: NOT STARTED, IN PROGRESS, IMPLEMENTED (qualification pending), QUALIFIED, BLOCKED. Include evidence for every transition.

| Milestone | Status | Notes |
|---|---|---|
| M00 | IMPLEMENTED (qualification pending) | Native Xcode target, portable contracts, synthetic audio-to-transcript test and macOS compile job. |
| M01 | IN PROGRESS | Native selected-process and microphone adapters, portable PCM replay, VAD and bounded streams. Real Mac validation and tighter real-time buffer handling remain. |
| M02 | IMPLEMENTED (qualification pending) | OpenAI WebSocket, normalized ordered finals, local commits, pre-roll and bounded reconnect. |
| M03 | NOT STARTED | Classifier, assembly and dedup; role policy is initial contract only |
| M04 | NOT STARTED | Response streaming |
| M05 | NOT STARTED | Knowledge and profiles |
| M06 | NOT STARTED | Native interface |
| M07 | NOT STARTED | MVP resilience |
| M08 | NOT STARTED | Secondary providers |
| M09 | NOT STARTED | Training and review |
| M10 | NOT STARTED | Retrieval and roles |
| M11 | NOT STARTED | Final qualification |

## Verification log

See `docs/verification/baseline.md` for the initial build/test run. No native Mac build, hardware permission test, paid provider call, CI workflow run or cloud task has been performed in this baseline. Record each future run and unresolved blocker here or in linked evidence documents.

### M00 development checkpoint

- 2026-11-24, Debian 13 x86_64, Swift 6.2.3 official Debian 12 distribution. GPG verified the archive against the Swift release key from swift.org. Writable module cache and SwiftPM manifest caching disabled for the cloud sandbox.
- `./scripts/build.sh --disable-sandbox --disable-package-manifest-caching` passed. The same options to `./scripts/test.sh` yielded 4 XCTest passes, 0 failures, 0 skipped.
- Reviewed Apple's process tap sample and the OpenAI Realtime transcription and streaming Responses guides. Xcode compilation, real tap permissions and live STT feasibility remain pending on macOS and with opt-in provider credentials.
- Next checkpoint is M01 selected-source capture, VAD, bounded buffering and replay.

### M01 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts with `--disable-sandbox --manifest-cache none` passed, 6 XCTest passes, 0 failures.
- Native source isolation, permissions, route changes and cleanup need Xcode and physical Mac checks. Current native callback copies bounded buffers into an asynchronous stream and still allocates per callback.
- Next checkpoint is M02 transcription. Native capture and VAD are available as injected source and endpoint contracts.

### M02 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts passed with 8 XCTest passes, 0 failures. Synthetic tests cover session configuration, duplicate deltas and out-of-order finals.
- OpenAI Realtime transcription wire configuration follows the official guide. Reconnect creates a fresh capture epoch and emits a gap. Live provider, injected disconnect and timeout checks are pending.
- Next checkpoint is M03 final interviewer turn classification and deduplication.
