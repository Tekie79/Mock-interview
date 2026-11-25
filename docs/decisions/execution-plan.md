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

Migrate existing pending items once, retaining their source and any explicit exclusions. Preserve the confirmed-only retrieval and embedding indexes so excluded content stays out of answers. Verify new attachments, the legacy upgrade and the native profile controls before updating the review PR.

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
