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

## Adjustable quiet window for question rounds

The owner reported that short pauses triggered answers early and rapid questions superseded one another. Add a session-level quiet window that collects successive finalized turns from the same interviewer and capture epoch before classification. Start the native default at two seconds and let the user adjust it during a session. Keep the provider's audio commit and the detector's incomplete-phrase timeout independent. Voice activity and new partials extend waiting. Partial text never enters an automatic request.

- Bound staged rounds and retain transcripts when staging overflows. Preserve source roles, transcript identities, late-attribution revocation, manual generation and lifecycle cancellation.
- Classify each collected round once. Preserve every accepted request in order in the generated text. Treat a question after an expired quiet window as a separate round under the existing supersession rule.
- Add clock-controlled tests for speech restarting, grouped/staggered finals, unresolved partials and cancellation. Run Swift build/test, unsigned packaging and the hosted CI matrix. This deliberately adds question latency and needs measured live acceptance.

Local Swift build and tests passed with 121 XCTest cases on the Apple Silicon Mac and 111 in the pinned Linux Swift container. The native unsigned package built and launched. The Settings walkthrough changed **Wait for silence** from 2 to 2.5 seconds, confirmed the displayed value, and restored 2 seconds. Clock-controlled cases cover resumed audio, two finalized questions, delayed finals, missing finals, pause, and a live timing change. No live capture or provider credentials were used for this check.

## Scenario answers and profile attachments

The owner wants scenario answers that open with a proposed approach and a clearer way to attach résumés, job descriptions, and Markdown files. Update the shared answer policy and the native Profiles editor. Conditional responses distinguish proposed actions from verified history. Approved facts remain the basis for personal claims.

- Offer a focused file picker for Markdown, text, PDF, and DOCX. Show each attachment name and type and keep pasted text in a separate control.
- Verify Markdown through the portable document reader and profile store. Preserve source text and keep imported experience claims pending until approved.
- Validate the shared prompt, file import regressions and native attachment controls. Run Linux and macOS testing and package the app without using live provider credentials.

Local macOS build and 124 XCTest cases passed. Pinned Linux Swift build and 114 XCTest cases passed. The unsigned native package launched, showed the attachment types and separate paste control, and enabled multi-selection of a synthetic `.md` and `.markdown` file. The picker was canceled before saving a profile. Portable tests verified storage, raw text retention, role type and approval boundaries. No live generation credentials were used.

## Profile evidence without a review queue

The owner requested removing the Pending and Review workflow. Attaching a résumé or project notes as experience, or entering an experience fact directly, makes it available for answers. Users can edit or exclude individual facts. Job descriptions remain target-role context.

The previous plan migrated existing pending items once. The owner later directed that pending facts stay excluded until explicitly enabled. The M11 acceptance correction supersedes that migration policy.

`./scripts/build.sh` and `./scripts/test.sh` passed on Linux Swift 6.2.3 (115 XCTest cases) and on the local Apple Silicon Mac (125 XCTest cases). `./scripts/package-macos.sh` built the unsigned application with one App Intents metadata warning. A native walkthrough backed by an in-memory synthetic profile verified the fact list, **Edit** and saving an exclusion using **Use in answers**. No personal profile, Keychain entry or live provider was used in this check.

## Concrete experience answers and practice scenarios

The owner reported that Talking points returned advice about what to mention instead of an answer to a past-experience question. Update the shared answer prompt and format instructions to produce speakable responses grounded in specific profile facts. For an unsupported past-experience question, generate one labeled, conditional practice scenario with concrete steps and an expected result. General technical and explicitly hypothetical questions still get direct answers in the requested format.

- Keep the selected profile across app launches and fix it for the session. Search the accepted question, its parts, the original wording, and a trusted referenced question so normalization and short follow-ups do not drop useful search terms.
- Verify automatic retrieval with a synthetic résumé, a competing job description, and a classifier that drops an acronym. Check shared generation inputs and instructions with relevant evidence, unrelated evidence and no profile. Run deterministic build and tests, unsigned packaging, and hosted CI. Live model adherence is distinct from the prompt and retrieval checks.

Local portable builds passed with 117 Linux Swift 6.2.3 and 127 Apple Silicon macOS XCTest cases, all passing. Unsigned arm64/x86_64 packaging passed with one App Intents metadata warning. Synthetic checks verify that the résumé reaches the answer request, job requirements and excluded claims stay out of the evidence, and a trusted follow-up retains access to the applicable facts. No personal profile or live provider was used.

## AI model and reasoning settings

Add provider-specific model and reasoning dropdowns to Question classification and Answer generation. Keep existing model settings and custom IDs. Store the choices independently by provider and service, and include them in saved presets. Keep the account-specific ChatGPT catalog and its eligibility gate.

- Centralize supported effort levels in the text model catalog. Keep live classification to low-effort choices within its current deadline. Use documented request fields and allow token headroom for reasoning while retaining the existing time limits.
- Exercise provider payloads and older presets with offline tests, then build and package the native app and run hosted portable and macOS checks. Higher effort can increase answer time and token usage. The connection test checks model access under the user's account.

Local Swift builds and tests passed with 120 Linux Swift 6.2.3 and 130 Apple Silicon macOS XCTest cases. Unsigned arm64/x86_64 packaging passed with one App Intents metadata warning. The isolated native form verified both model menus, independent reasoning choices, the disabled state for GPT-4.1 mini, and custom model entry. Fixtures checked provider request fields and legacy preset decoding. No live provider credentials were used.

## Profile training and first-person project answers

Add profile inputs for skills and a sample of the candidate's speaking style. Let the candidate record a real project with its source, destination, data, contribution, and outcome as one reusable experience fact. Existing profile records and attachments remain usable.

- Broaden retrieval for past-work questions by supplying a bounded shortlist of approved project examples alongside query matches. Keep sample text as style context and job requirements as role context. Use a suitable real project for broad questions and state the actual scope for related experience. Reserve hypothetical answers for questions requesting hypothetical work.
- Verify profile persistence, source and status boundaries, the automatic broad-question path, prompt separation, native editing, portable builds and unsigned packaging. Live model adherence needs separate verification.

Local builds passed with 123 Linux Swift 6.2.3 and 133 Apple Silicon macOS XCTest cases, all passing. The unsigned universal app built with one App Intents metadata warning. The isolated native profile accepted skills, a speaking sample, and a saved synthetic project with source, destination, data and contribution. Deterministic tests verified the broad-question payload, project evidence isolation and the ordinary technical path. The check used no personal profile or live provider.

## Compact session controls

Show Start in the idle Compact window and Resume when paused. Share the session buttons and availability checks with the main workspace. Surface startup failures in Compact so they can be diagnosed without expanding. Verify the controls in a native preview with synthetic state transitions, then run the build, tests and unsigned packaging.

The native preview verified Start, Pause, Resume and Stop at the minimum Compact width, disabled Start during an audio test, and a visible missing-source error. Local macOS passed 133 tests and unsigned packaging. The first local Linux run timed out in the existing transcription watchdog test. The full retry passed all 123 tests. The preview used a simulated session and did not capture audio.

## M11 acceptance defect correction and qualification

Baseline is `41c243a1b7a72ea69b71940acd4c7edd615e732b` on `feature/m11-final-acceptance`. Keep PR #3 in draft and retain the current release and ChatGPT eligibility restrictions.

- Freeze a fresh held-out corpus before evaluating the changes. Preserve separate evidence for language gating, audio boundaries, rendered latency, and remote endurance. Record actual outcomes and the device, credentials or peer needed for unmet tests.
- Address shared-feed false positives in the question detector and reuse existing speaker assignment on mixed process feeds. Audit Scribe v3 Live segment association against its documented commit modes. Check route notifications and retry behavior against repeated physical changes when available.
- Keep new evidence immediately usable. Audit document boundaries and exclusions. Resolve legacy pending semantics using the owner's policy and retain prior user edits when provenance cannot be established. Label the answer length control according to what generation guarantees.
- Run unit and integration regressions, unsigned native packaging, and the full hosted Linux/macOS 15/macOS 26 matrix. Report measured and unexecuted acceptance cases separately, including remaining provider, hardware and latency gates.

The owner confirmed existing pending facts must stay excluded until enabled and confirmed no remote endpoint is available. The new corpus was frozen before the corrections. Local Xcode build, 139 tests and unsigned packaging passed. A recorded human Q&A diagnostic and baseline/candidate physical output probes ran at the adapter layer. The provider strategy matrix, live model and grounding trials, physical microphone/overlap and true remote endurance still need their required environments. Exact hosted checks and the final commit are recorded on [draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3).

## M11 continuation after b2946d6

- Narrow the transcript-only rejection in `QuestionDetection` and add regression cases for direct, indirect and conversational interviewer prompts. Keep the independent speaker-role, lifecycle and duplicate gates.
- Use the app's ordinary Keychain path. Ask the owner to respond to macOS prompts if needed. Keep the frozen audio corpus, Scribe strategy comparison, OpenAI model/effort matrix, and native capture/grounding checks within the approved US$10 total.
- Provide a repeatable 90-minute synthetic remote playback track with a separate candidate reference and scoring manifest. Run the native endurance case when a second endpoint is available. Keep provider use and output measurement distinct from local playback preparation.
- Run the portable regression matrix and unsigned native packaging. Record exact revision and test output on PR #3, with separately scoped evidence for physical hardware, live providers and displayed latency.
- Address repeated prompts reported during native tests. Reuse credentials whose reads macOS authorized for the current app launch, serialize Keychain operations off the main thread, and make microphone and Speech permission prompts conditional on the current OS status. Retain the original Keychain access control and OS-managed process-tap authorization.

## M11 release candidate after f726664

- Reproduce starvation before changing the pipeline. Bound round lifetime and ownership in `InterviewSession` and `QuestionDetection`. Verify final-only evaluation, continuation, role and epoch invalidation, queue pressure, and replay drain.
- Make question-source trust explicit in the route model and native setup. Inspect native initialization ownership and Scribe finalization against the official contracts and reproduce faults at the available test layers.
- Freeze an independent holdout before final qualification. Record hardware, provider spend, visible latency, grounding and AT-01–18 by tested layer. A second remote endpoint, credentials where missing and distribution authorization are external dependencies.
- Run the complete automated matrix and an unsigned versioned build. Update the acceptance reports and draft PR #3 with exact revision and artifact identity. Keep unpassed release requirements open.

The exact baseline failed the deterministic 100-turn reproduction with 0/40 recovered requests. The correction recovered 40/40. A recorded-speech regression exposed early splitting at the initial hard deadline. With a bounded eight-second packet, a one-second wait combined the recorded 750 ms gap and separated the 1,500 ms gap. `./scripts/build.sh`, `./scripts/test.sh` with 153 passes, `./scripts/package-macos.sh`, holdout validation and `git diff --check` passed locally. The new 100-cue synthetic holdout completed 30 local SpeechAnalyzer files. The native setup stall reproduced in OS audio authorization for the unsigned code identity. All three matched live Scribe retests reproduced unresolved audio at drain. The owner confirmed no remote endpoint is available. The exact hosted results and open live qualification work are on [draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3).

## M11 OpenAI production scope after 224627c

- Qualify OpenAI Realtime, Responses and embeddings within the existing cumulative US$10 budget. Keep alternate provider code and fixtures. Record excluded live provider configurations and preserve the ChatGPT eligibility gate.
- Add optional Chat alongside Focus in the native workspace and compact window. Use the same capture, history and generation. Verify scrolling, streaming, invalidation and fit at compact width.
- Extend session context with bounded, attributed original turns and optional background OpenAI summaries. Keep profile evidence and generated suggestions outside learned conversation context. Exercise correction, cancellation and reset without an additional request in the answer path.
- Run portable tests, native unsigned packaging and exact-revision hosted checks. Record applicable live evidence and leave unexecuted native and performance gates open.

Local SwiftPM build and 159 XCTest cases passed with zero failures. Xcode built unsigned version 1.0.0 (11.2) for arm64 and x86_64. Hosted checks, native UI observations and provider measurements are indexed in [draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3).

## M12 native redesign

Base `a843a565ef0c9f7ed5d4c9a3bb3bd9bb5a318d0a` on `feature/m12-modern-ui`.

- Split the native shell into navigation, live, answer, inspector, settings, profiles, practice and review surfaces. Add semantic design tokens and keep one workspace model above navigation.
- Add viewport-based answer visibility, shared actions, stable chronological cards, follow controls, bounded updates and narrow Compact layout.
- Add session-local Recent and Adaptive policies, capture-time context selection, inspection and editing, and provenance invalidation.
- Run deterministic regressions, unsigned Release packaging and hosted Linux, macOS 15 and macOS 26. Inspect the native UI with synthetic content. Keep OpenAI hardware, independent accuracy/display timing, endurance and distribution qualification separate.

M12 verified the local Swift package and unsigned native Release and Debug builds. Native synthetic runs exercised shared windows, Chat follow controls, attributions, withdrawn answers and the seven settings categories. A two-window Chat burst exposed a layout stall. M12 replaced the eager stack layout with a native virtualized list and passed a 200-answer synthetic retest. PR #4 records exact hosted checks and archive verification. Physical dual-source, independent OpenAI accuracy and latency, remote endurance, and clean installation and upgrade remain open.

### M12 system-output follow-up

Reproduce the reported silent speaker route on the running unsigned archive. Compare actual submitted frames, transcript results and question dispositions. Retest physical speaker capture with local audio while Zoom is open. Keep mixed-source attribution fail closed. Make the active answer mode and transcript path visible, verify meter identities, run the regression suite and rebuild the unsigned app. macOS may request authorization when an unsigned build changes identity.

The native follow-up verified physical speaker RMS, then six live Zoom transcript finals and two completed automatic answers after the owner confirmed the interviewer-only route. The 12.1 fixture displayed both Start options for an unconfirmed system output. Local portable build, 165 tests and unsigned universal Release packaging passed. Hosted evidence is linked from PR #4.
