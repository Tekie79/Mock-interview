# M11 final acceptance execution

Use the local Apple Silicon Mac and branch `feature/m11-final-acceptance`, based on approved M10.2 commit `6fdcc4b3e35c489499e4f1014cd69f5ce98167ed`. The review PR targets `feature/m10-2-final-development`. Keep the ChatGPT live eligibility gate closed pending documented owner approval. Release signing and publication require separate owner authorization.

| Checkpoint | Execution and evidence |
|---|---|
| A | Inventory the environment, run SwiftPM builds and tests locally where supported, and validate the hosted Linux and macOS 15/26 matrix and unsigned package. Keep exact artifact identity in evidence. |
| B | Launch a local native bundle and test its UI. Exercise available capture, role gating, local recognition, profile import, retention, and failure paths independently of credentials. Preserve existing settings and do not expose secrets or user content. |
| C | Exercise the complete acceptance matrix using distinct development and held-out labels. Qualify each available live provider with synthetic audio. Collect independently annotated speech-end and visible-response timing and run a real 90-minute remote session when configuration and spending are authorized. |
| D | Apply the owner-requested answer types and length controls in the workspace and Compact view. Verify typed layouts, context preferences and length precedence with synthetic content. Keep launch credential checks silent and stop standalone live-provider probes. |
| E | Record and retest defects with deterministic coverage. Update the six qualification documents, README, traceability, implementation status and acceptance plan. Run the hosted matrix against the PR head and report actual outcomes and remaining gates. |

Xcode 26.6 is installed and local native packaging passed. Portable Swift tests, the corpus manifest, native workspace and selected audio routes, and live provider smoke completed on the host. M11-01 has a native window regression procedure. M11-04 and M11-05 have behavioral regression tests. Physical audio topologies, the complete 90-minute and latency gates, and provider eligibility are tracked in the [M11 acceptance record](../verification/m11-final-acceptance.md). The review PR records exact-head CI results.

## Other-device interview and shared microphone

The owner requested an explicit mode for a Mac microphone that hears the candidate and an interview running on another device. Extend the existing mixed-microphone role gate on the M11 feature branch. Preserve explicit source selection and Start, text-only answers, and the current provider choices.

- Add a native toggle and role-assignment guidance. Keep the selected classification and answer providers independent.
- Implement the official ElevenLabs Scribe v3 Live speaker events alongside the existing Deepgram path. Pair stable commits with diarized results by segment index, keep unresolved or mixed turns ineligible, and revoke affected automatic answers if a speaker merge changes attribution.
- Exercise mixed, unknown, candidate, interviewer, duplicate, reset, and merge cases with synthetic events. Run portable build/test and unsigned macOS packaging. Keep real-room accuracy and live account qualification separate from deterministic evidence.

The local Swift build and 117 XCTest cases passed. The unsigned arm64/x86_64 app built with Xcode 26.6. The native walkthrough toggled the room route, verified the microphone picker and provider guidance, and restored the previous Zoom source. The test left capture idle. These checks use synthetic speaker events. Live provider behavior and physical room attribution still need qualification.
