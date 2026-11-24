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

Targets (unmeasured): first useful visible text p50 ≤ 1.5 s / p95 ≤ 3.5 s; complete brief answer p95 ≤ 7 s on successful requests; question precision ≥ 95%, recall ≥ 90%; candidate-triggered responses zero in dual-channel deterministic tests; exact duplicate ID tests zero duplicates. Record model, OS, hardware, network, sample size, p50/p95, failures and denominator. Mixed microphone performance must be measured independently. No target is guaranteed by the baseline.

For each run record: commit SHA, date, OS/toolchain/device, command or manual steps, fixture version, test count, passes/fails/skips, artifacts, limitations, next action. Never treat not-run as pass. Keep real personal content out of published test evidence. Initial fixtures are development examples, not a qualification corpus (target at least 200 development and 100 distinct held-out utterances per spec).
