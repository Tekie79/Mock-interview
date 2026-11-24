# Implementation status

Baseline is a repository bootstrap only; no real application or provider integration. Status vocabulary: NOT STARTED, IN PROGRESS, IMPLEMENTED (qualification pending), QUALIFIED, BLOCKED. Include evidence for every transition.

| Milestone | Status | Notes |
|---|---|---|
| M00 | IMPLEMENTED (qualification pending) | Native Xcode target, portable contracts, synthetic audio-to-transcript test and macOS compile job. |
| M01 | NOT STARTED | Real capture and replay engine |
| M02 | NOT STARTED | Real streaming STT |
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
