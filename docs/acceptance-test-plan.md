# Acceptance and verification plan

Full scenario definitions and metric methodology: requirements §12. Final acceptance M11 follows feature implementation. Milestone unit, contract and integration tests are required continuously. No qualification claims from synthetic tests alone.

| Gate | Spec scenarios | Test layer / evidence |
|---|---|---|
| G1 role and semantic detection | AT-01–09, AT-18 | Synthetic labels, deterministic role gate, provider event duplication/reorder and semantic test cases; distinct held-out data |
| G2 lifecycle and errors | AT-10, AT-12–13, AT-15 | Virtual time; cancellation, source failure, reconnect, bounded buffering, stale epoch, secret redaction |
| G3 personal evidence | AT-11, AT-14 | Approved facts vs. job requirements, absent/conflicting facts, injected text, no-save storage and logs |
| G4 deterministic replay | AT-17 | Repeatable pipeline with fake STT, classifier and generator; no keys/network |
| G5 native product | AT-01–18 as applicable | Xcode build, explicit permission denial/allow, Zoom/Teams/Meet selected process, source exit, mic route, compact window, accessibility |
| G6 performance | AT-16 plus §12 metrics | Annotated end-of-question timing, 90-minute session, held-out labels, memory/CPU, failure accounting |

Acceptance targets: first useful visible text p50 ≤ 1.5 s / p95 ≤ 3.5 s; complete brief answer p95 ≤ 7 s on successful requests; question precision ≥ 95%, recall ≥ 90%; candidate-triggered responses zero in dual-channel deterministic tests; exact duplicate ID tests zero duplicates. Record model, OS, hardware, network, sample size, p50/p95, failures and denominator. Mixed microphone performance must be measured independently. No target is guaranteed by the baseline.

For each run record: commit SHA, date, OS/toolchain/device, command or manual steps, fixture version, test count, passes/fails/skips, artifacts, limitations, next action. Never treat not-run as pass. Keep real personal content out of published test evidence. Use at least 200 development turns and 100 distinct held-out turns. The [M11 corpus](../Tests/Fixtures/m11/README.md) supplies separately rendered and labeled splits.

## M10.1 inputs to M11

- Use physical devices and separate candidate/interviewer audio for each supported output class, and record driver, OS, process grouping, default route following, explicit device removal, recovery, sleep/wake and quit behavior.
- Check Speech Recognition permission, classic and installed SpeechAnalyzer modes, ElevenLabs strategies, OpenAI and Deepgram drains, valid and invalid credentials, supported models, context budgets, and separate provider billing.
- Measure speech-end to useful displayed text against an annotated reference. Report all failed and timed-out requests, per-stage durations and missing timing boundaries. Include multi-part prompts, candidate-dependent follow-ups and mixed-speaker recordings.
- Qualify ChatGPT plan use only after distribution eligibility, model and authorization are verified. No real account or hardware was used in the M10.1 development suite.

## M11 execution

Use the [AT-01–18 evidence table](verification/m11-final-acceptance.md) for current status and report Passed, Failed, Blocked or Not tested. Keep pipeline estimates and live text classification distinct from independently timed displayed responses and real audio question accuracy. For the compact window regression, launch the native application, open Compact from the workspace, click Expand, and verify that the Window menu and accessibility tree show the same single workspace. Repeat after opening Compact with the configured shortcut.
