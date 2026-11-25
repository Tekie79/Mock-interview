# M10.2 development execution

Branch `feature/m10-2-final-development` starts from reviewed M10.1 commit `42b8dda68ecc05a00a529a59cd03975e4ce56c05`. Preserve V1 features and the macOS 14.2 deployment target. Do not start M11, merge, or publish a release.

| Checkpoint | Scope, files and development evidence |
|---|---|
| A | ElevenLabs protocol and `TranscriptionChannel`: distinct audio, utterance and drain states; mocked delayed, duplicate, empty, timed-out and cancelled finals; silence-safe watchdog and retry tests |
| B | `InterviewSession` and `PipelineMeasurements`: bounded cross-source attribution and timestamp provenance; arrival order, overlap, repeats, reset, reconnect and display acknowledgment regression |
| C | ChatGPT authorization and AppShell: synthetic browser/loopback, account lifecycle and subscription composition; live activation remains gated on documented eligibility; audit independent provider settings and contracts |
| D | Native Core Audio and SpeechAnalyzer: remove warning causes, review buffer/converter ownership and task cleanup; test portable lifecycle and compile/package on macOS 15 and 26 |
| E | Run the full portable and hosted suites; update traceability, provider compatibility, implementation status and exact-head verification; open the review PR against M10.1 |

Use `./scripts/build.sh`, `./scripts/test.sh`, and `git diff --check`. Hosted macOS runners must also run `./scripts/package-macos.sh`. Keep untagged provider timing and acoustic correlation limitations explicit: silence is not a stalled recognizer, a partial is not a final, and transcript evidence cannot prove acoustic isolation. No real authorization, paid-provider traffic, signing, or physical acceptance is part of these checkpoints.

The branch already contained uncommitted M10.2 implementation and regression fixtures at the reviewed base. Preserve those changes, record them as a development checkpoint, and run hosted CI while auditing the remaining edge cases. The local Swift 6.3.2 Command Line Tools build passed. Local XCTest requires the Xcode test SDK, so use the Swift 6.2.3 Linux container and the hosted macOS matrix for full results.

Checkpoint `2620b3d` passed all three hosted build and test jobs. The macOS 26 packaging check uncovered a missing Core Audio permission key after a successful compile. The follow-up adds explicit app permission metadata, tests overlapping speech coverage and delayed identical finals, and tightens provider readiness and native timestamp correlation. Run the same hosted matrix on the follow-up and record results for the PR head in the review description. See [M10.1 verification](../verification/m10-1.md) and [M10.2 verification](../verification/m10-2.md).
