# Implementation status

The original bootstrap is documented in the baseline evidence below. Status vocabulary: NOT STARTED, IN PROGRESS, IMPLEMENTED (qualification pending), QUALIFIED, BLOCKED. Include evidence for every transition.

| Milestone | Status | Notes |
|---|---|---|
| M00 | IMPLEMENTED (qualification pending) | Native Xcode target, portable contracts, synthetic audio-to-transcript test and macOS compile job. |
| M01 | IMPLEMENTED (qualification pending) | Selected process and microphone capture, PCM replay, VAD, preallocated native capture buffers and bounded streams. |
| M02 | IMPLEMENTED (qualification pending) | OpenAI WebSocket, normalized ordered finals, local commits, pre-roll and bounded reconnect. |
| M03 | IMPLEMENTED (qualification pending) | Final interviewer gate, incomplete-turn assembly, deduplication, context and OpenAI structured classification. |
| M04 | IMPLEMENTED (qualification pending) | OpenAI SSE, grounded prompt, session composition, answer formats, manual generation and revision guards. |
| M05 | IMPLEMENTED (qualification pending) | SQLite profiles/documents/facts, confirmed-only FTS and text/Markdown/PDF import contracts. |
| M06 | IMPLEMENTED (qualification pending) | Live SwiftUI workspace, source setup and meters, profile review, compact window, shortcuts and Keychain. |
| M07 | IMPLEMENTED (qualification pending) | Bounded retry, redacted diagnostics, usage, synthetic replay, in-memory retention and packaging command. |
| M08 | IMPLEMENTED (qualification pending) | Deepgram PCM WebSocket, Anthropic classifier and answer streams, configurable independent provider/model settings. |
| M09 | IMPLEMENTED (qualification pending) | Opt-in saved history with SQLite search, review and missed questions, text export, and solo practice with AI-estimate coaching. |
| M10 | IMPLEMENTED (qualification pending) | DOCX text extraction, opt-in hybrid retrieval, and explicit epoch-scoped roles for diarized mixed microphone speech. |
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

### M09 development checkpoint

- Debian 13, Swift 6.2.3. Build and tests passed, 18 XCTest passes, 0 failures. Added no-save baseline, history FTS update/deletion and actual-versus-suggested separation assertions. macOS-target Swift syntax parse passed.
- The M09 macOS workflow passed portable checks and surfaced two native review error-binding compile errors. Both are corrected in the M10 checkpoint. Native review walkthrough and live coaching quality checks are pending. Solo practice uses text prompts and typed answers.
- Next checkpoint is M10 DOCX extraction, optional vector retrieval and explicit mixed-microphone speaker mapping.

### M10 development checkpoint

- Debian 13, Swift 6.2.3. Build and test scripts passed, 22 XCTest passes, 0 failures. New fixtures cover deflated DOCX extraction and malformed input, model-scoped vectors and revoked evidence, mixed word labels, fail-closed unknown roles, candidate immunity and fresh epochs. Apple-target source parsing and `git diff --check` passed.
- Deepgram diarization is opt-in for mixed microphone mode and accepts only user-mapped, single-speaker final turns. Roles clear at reconnect. Embeddings are opt-in and require an explicit index build. Keywords remain available if a vector model is unavailable.
- M11 is reserved for final acceptance. Real Mac audio, OS permissions, provider smoke, held-out role/semantic quality, latency, 90-minute stability, accessibility and packaging qualification require the appropriate machine and opt-in credentials. The final hardening checkpoint uses preallocated native capture buffers. Callback performance still needs physical real-time measurement.
- Exact next checkpoint: on an Apple Silicon Mac, open the branch, run `./scripts/package-macos.sh`, exercise selected app audio and mic permission/route/stop behavior with a synthetic practice call, run each configured provider's opt-in connection and audio smoke, and record the M11 scenario and benchmark evidence from `docs/acceptance-test-plan.md`.

### Development verification and hardening

- GitHub Actions run [45504965184](https://github.com/Tekie79/Mock-interview/actions/runs/45504965184) passed the portable build, 22 deterministic tests and the unsigned Xcode Release app build at the M10 commit `fd6e322`.
- Linux build and 24 deterministic tests passed on the hardening checkpoint. Verified fixed audio-slot capacity and reuse and separation of job requirements from approved facts. Native source parse and diff check passed.
- Hardened capture with a preallocated lock-free slot pool, limited meter updates, and added sleep pause, WebSocket send cancellation and configurable local shortcuts. Added target/job context to generation independently of confirmed facts.

## M10.1 development

- A: Implemented — qualification pending. Transcript ingestion feeds a bounded independent classifier queue. Per-source lifecycle drives session state, with source/epoch/revision guards and an explicit overflow counter. Linux baseline and two targeted regressions passed.
- B: Implemented — qualification pending. Provider readiness precedes capture, committed segments drive bounded replay drain, and role-labelled context and stage measurements are wired to classification, generation and the view. Linux 28 tests passed. Physical capture time and provider-specific endpoint behavior remain qualification work.
- C: Implemented — qualification pending for supported single-stream Core Audio outputs, stable device preferences, process bundle grouping, separate candidate mic selection, route changes, and runtime replacement. Hardware-dependent routing, helper grouping and acoustic quality remain pending. Attribution uses conservative recent exact candidate-text correlation.
- D: Implemented — qualification pending. Provider/service capabilities, billing and authentication distinctions, word and utterance metadata, separate commit modes, and readiness contracts are defined. Linux 32 tests passed at D.
- E: Apple Speech adapter implemented against the deployed Speech recognizer API with strict on-device enforcement, locale discovery and per-segment request rollover. Linux 33 tests passed. Apple SpeechAnalyzer and live recognition behavior are pending.
- F: ElevenLabs Scribe v3 Live and v2 Realtime WebSocket paths implemented, including endpointing strategies, model validation, replacement partials, timestamped finals, and normalized failure handling. All three mocked transport tests passed. Live account availability and billing details are pending.
- G: OpenAI Realtime acknowledges configuration before capture, uses model-specific prompt and delta handling, and exposes cancellable transport. Deepgram flushes provider-finalized words on CloseStream metadata and keeps unknown speakers fail closed. Linux 39 development tests passed. Hosted macOS run 45534615162 passed checkpoint C.
- H: Blocked for live sign-in. OpenAI documents a local/open-source preview and restricted partner access. Repository distribution eligibility is unresolved. Added OAuth request/callback validation, signed identity checks, isolated token rotation and revocation, and the authorized Responses/model-catalog boundary. 42 Linux development tests passed. Subscription transcription and embeddings are unavailable.
- I: Independent configuration, capability-aware recognition options, per-service testing, context/timeout controls, and local preset CRUD implemented. Unsupported subscription presets remain visible and inapplicable. Linux 43 tests passed. Hosted macOS run 45535622177 passed checkpoint G, including Apple Speech compilation.
- J: Added macOS 26 installed SpeechAnalyzer routing, explicit quit cleanup, audio usage diagnostics, pending-commit timeouts and final audit. Linux build and 46 development tests passed. Native source parsed for arm64; local packaging returned the expected Xcode-required error on Linux. Hosted checkpoint I passed at [75faf07](https://github.com/Tekie79/Mock-interview/actions/runs/45536409552). The final commit's hosted result belongs in the pull request.
- Remaining M10.1 gaps: confirmed ChatGPT eligibility and browser linking, complete provider-runtime regression matrix, and full correlatable timing for provider-owned segmentation. M11 hardware/live smoke and target measurements remain untouched. See the [requirements traceability](requirements-traceability.md) and [verification record](verification/m10-1.md).
- Review follow-up: explicitly invalid provider selections fail closed, and stale recognition epochs are rejected before timing or drain acknowledgments. The Linux suite passed 47 tests.
- Timing follow-up: timestamped Deepgram, ElevenLabs and SpeechAnalyzer results can be correlated against recent sample-clock anchors. Timestamp-less or reset ranges fall back to local observation where available. Linux 48 tests passed.
