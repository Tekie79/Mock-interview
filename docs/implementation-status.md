# Implementation status

Baseline is a repository bootstrap only; no real application or provider integration. Status vocabulary: NOT STARTED, IN PROGRESS, IMPLEMENTED (qualification pending), QUALIFIED, BLOCKED. Include evidence for every transition.

| Milestone | Status | Notes |
|---|---|---|
| M00 | IMPLEMENTED (qualification pending) | Native Xcode target, portable contracts, synthetic audio-to-transcript test and macOS compile job. |
| M01 | IN PROGRESS | Native selected-process and microphone adapters, portable PCM replay, VAD and bounded streams. Real Mac validation and tighter real-time buffer handling remain. |
| M02 | IMPLEMENTED (qualification pending) | OpenAI WebSocket, normalized ordered finals, local commits, pre-roll and bounded reconnect. |
| M03 | IMPLEMENTED (qualification pending) | Final interviewer gate, incomplete-turn assembly, deduplication, context and OpenAI structured classification. |
| M04 | IMPLEMENTED (qualification pending) | OpenAI SSE, grounded prompt, session composition, answer formats, manual generation and revision guards. |
| M05 | IMPLEMENTED (qualification pending) | SQLite profiles/documents/facts, confirmed-only FTS and text/Markdown/PDF import contracts. |
| M06 | IMPLEMENTED (qualification pending) | Live SwiftUI workspace, source setup and meters, profile review, compact window, shortcuts and Keychain. |
| M07 | IMPLEMENTED (qualification pending) | Bounded retry, redacted diagnostics, usage, synthetic replay, in-memory retention and packaging command. |
| M08 | IMPLEMENTED (qualification pending) | Deepgram PCM WebSocket, Anthropic classifier and answer streams, configurable independent provider/model settings. |
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

### M03 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts passed, 9 XCTest passes, 0 failures. Synthetic tests cover the role and freshness gate, incomplete continuation, logistics, duplicate items and repeat identity.
- The real classifier uses the Responses API and strict JSON schema. Live model validation and a held-out semantic evaluation are pending.
- Next checkpoint is M04 streamed generation and stale revision protection.

### M04 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts passed, 11 XCTest passes, 0 failures. Added fragmented UTF-8/SSE parsing and controlled generation tests for supersession, evidence injection and pause.
- Native end-to-end replay/UI, provider smoke and latency measurements remain pending.
- Next checkpoint is M05 persisted profiles, imports, fact review and keyword retrieval.

### M05 development checkpoint

- Debian 13, Swift 6.2.3 and Debian SQLite 3.46.1. Build and test scripts passed, 12 XCTest passes, 0 failures. SQLite development files were extracted from signed Debian package metadata into the workspace toolchain and passed through compiler and linker include paths.
- Tests verify pending/confirmed facts, profile isolation, job description exclusion, limitations and document deletion. PDFKit is Mac-only and its runtime import path still needs validation.
- Next checkpoint is M06 native session controls, profile editor and Keychain-backed settings.

### M06 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts passed, 12 XCTest passes, 0 failures. Swift frontend parsing passed for arm64 macOS 14.2 source. This is syntax coverage only.
- Feature-branch CI now requests Xcode compilation. Native walkthrough, VoiceOver, local keyboard and selected-source permission tests remain pending.
- Next checkpoint is M07 resilience, retention, diagnostics and packaging.

### M07 development checkpoint

- Debian 13, Swift 6.2.3. Build and tests passed, 14 XCTest passes, 0 failures. PCM-to-answer integration covers duplicate final delivery, usage, stop and transcript-free diagnostics. Native source parsed and packaging script passed shell syntax validation.
- The hosted macOS workflow is building the M06 checkpoint. Validate packaging output on a subsequent runner. No credentialed connection tests or physical Mac scenario matrix ran here.
- Next checkpoint is M08 independent Deepgram and Anthropic provider selection.

### M08 development checkpoint

- Debian 13, Swift 6.2.3. Build and tests passed, 17 XCTest passes, 0 failures. Added Deepgram request and endpoint assembly fixtures and Anthropic delta, usage and error fixtures.
- Reviewed official Deepgram streaming/finalization and Anthropic streaming/structured-output documentation. Live accounts and selected model availability remain unverified.
- GitHub Actions run 45503029168 passed Swift build, tests and Xcode compilation at M06 (cbc1bb8). This provides compile evidence only.
- Next checkpoint is M09 optional history, review and solo practice.
