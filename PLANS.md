# Development plan

Canonical roadmap: `docs/requirements.md` §13. Milestone status lives in `docs/implementation-status.md`. Keep one active execution plan in `docs/decisions/execution-plan.md` (revise it for the active task). Break large milestones into reviewable commits or PRs and test each increment. Final acceptance runs after implementation, not instead of milestone tests.

| ID | Deliverable | Evidence required | Suggested branch |
|---|---|---|---|
| M00 | SwiftPM boundaries, native app project, fixture pipeline, feasibility contracts | Core build/tests; Xcode and tap/provider spikes separately verified or pending | feature/m00-foundation |
| M01 | Process/mic/replay capture, VAD, bounded frames, source lifecycle | Replay/lifecycle tests; real source isolation and cleanup on Mac | feature/m01-audio-capture |
| M02 | OpenAI live STT, normalized transcript assembly, reconnect | Protocol event fixtures, commits, gaps, ordering; real provider test | feature/m02-live-stt |
| M03 | Role gate, semantic question classifier, turn context, dedup | Labeled cases, unknown/candidate fail closed, exact duplicate suppression | feature/m03-question-intelligence |
| M04 | Grounded streaming text, cancellations, response formats | End-to-end deterministic audio/event-to-answer demo and cancellation tests | feature/m04-answer-streaming |
| M05 | Profiles, imports, fact review, SQLite FTS | Retrieval/grounding regressions, retention | feature/m05-knowledge |
| M06 | Live workspace, compact window, settings, keyboard and accessibility | Native UI build/test and complete P0 walkthrough | feature/m06-live-ui |
| M07 | Recovery, diagnostics, packaging, MVP readiness | P0 matrix, known blockers, no placeholders in required paths | feature/m07-mvp |
| M08 | Deepgram and Anthropic adapters | Independent model/provider settings and contract/smoke tests | feature/m08-providers |
| M09 | Review, exports, solo practice, rubric | Actual vs. suggestion separation, training workflow | feature/m09-training |
| M10 | DOCX, optional embeddings, mixed-mic role resolution | Separate role quality and retrieval tests | feature/m10-retrieval-roles |
| M10.1 | Real-time pipeline, output routes, independent providers and audit | [Traceability](docs/requirements-traceability.md), regression suite and macOS package build | feature/m10-1-pipeline-hardening |
| M11 | Final qualification | Real-Mac regression, latency, 90-min sessions, packaging | feature/m11-qualification |

P2 local AI and Windows require owner approval. A cloud workstream can implement multiple dependent milestones on one feature branch with separate checkpoints; do not wait for final hardware acceptance before writing the remaining portable code. Mark each platform/provider blocker accurately. Avoid concurrent branches that modify the same contracts.
