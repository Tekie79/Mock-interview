# M11 final acceptance

**Hold release.** The M11 correction passed local regression tests and unsigned packaging. Live shared-feed quality, Scribe strategy comparison, physical microphone attribution, visible-answer timing and the real 90-minute run remain open. The reports below distinguish current results from historical smoke. [Benchmark](m11-performance-benchmark.md) · [Provider results](m11-provider-qualification.md) · [Audio compatibility](m11-audio-compatibility.md) · [Defects](m11-defect-register.md)

## Continuation after b2946d6

The new first-person, indirect and conversational regression rejects the reviewed baseline. Six of ten legitimate requests were dropped before classification. All ten reach the semantic classifier on the correction. Narration and uncertain intent also reach it, and fixture decisions of ignore or uncertain create no cards.

The live replay and model checks used build `37bc058`. Its Release executable SHA-256 is `2b10463b578160d33d9e5c6e853d87b367d141764b346bf2dcdcdf6d906e3920`. The subsequent permission correction passed 142 local XCTest cases and unsigned universal packaging on Xcode 26.6 (17F113). Its Release executable SHA-256 is `d6fb557939e04e1037af2e9a0c4dc486c66e8f3f74f6e12f729030bc3e829675`. Per-job logs and exact source revision are on [draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3).

The native frozen-corpus run failed the question recall gate with one second of silence waiting on a single mixed feed. The app produced 95 finals and zero cards and reported a question buffer overflow. The independent Apple SpeechAnalyzer run covered 100/100 clips with 4.82% normalized WER. The recorded-speech wait probe used controlled provider finals and found that 1 second combined parts across a 750 ms gap, while 2 seconds was needed for the 1,500 ms case. [Benchmark](m11-performance-benchmark.md)

The application used the owner-approved Keychain path for native provider checks. All three live Scribe modes completed five cards each on the matched replay and reported unconfirmed audio at drain. The separate native candidate microphone and output were selectable, but Test Audio stalled in Core Audio setup before delivering usable meters. Live speaker assignment and full profile grounding remain open. The 90-minute tracks and cue sheet are ready. AT-16 remains blocked by the unavailable second endpoint. [Provider results](m11-provider-qualification.md) · [Native audio](m11-audio-compatibility.md) · [Remote playback setup](../../Tests/Fixtures/m11/README.md#90-minute-remote-playback)

## Acceptance correction after 41c243a

The work continues from `41c243a1b7a72ea69b71940acd4c7edd615e732b`. [Draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3) records the final commit and links its hosted Linux, macOS 15 and macOS 26 checks.

| Area | Current evidence | Gate |
|---|---|---|
| Regression and app bundle | `./scripts/build.sh`, `./scripts/test.sh` and `./scripts/package-macos.sh` passed on local Xcode 26.6 (17F113), macOS 26.3.2 (25D2150). XCTest ran 139 tests with zero failures and zero skips. The unsigned Release bundle includes arm64 and x86_64 and targets macOS 14.2. Release executable SHA-256 `96270f8e54aff510098b4b8f278239b4ac8810f14079efc91c1724b28b49afa7`. SwiftPM reported five pkg-config search diagnostics and Xcode reported one App Intents metadata warning. Zero Swift or Clang compiler warnings. | Local pass |
| M11-08 shared feed | Explicit speaker assignment fails closed for unknown roles. The question gate retained all three requests and rejected four of six negative turns on human Q&A through local Apple recognition. Two ambiguous turns reached a permissive classifier fixture. | Open. Needs live audio-to-card precision, recall, duplicate and premature counts. |
| M11-06 segmentation | Offline tests cover plain and timestamped finals arriving in different orders, including punctuation variation and partial audio coverage. | Blocked for current live comparison by credential access. |
| M11-02 output changes | Baseline and correction each recorded audible signal on 20 alternating default and explicit physical output starts. Configuration-equivalent HAL events now leave the existing tap open. | Adapter retest passed. Intermittent native failure did not reproduce. Native UI retest remains open. |
| AT-02 and AT-18 | Candidate and unknown role regressions passed. The physical helper had undetermined microphone permission. | Physical candidate mic, overlapping voices and assigned speaker labels still require native verification. |
| AT-05 and AT-07 | Four wait times exercised with clock-controlled provider finals. At 1 and 2 seconds, the 750 ms gap produced one combined question. | Recorded native pauses and completeness of the generated answer still require verification. |
| AT-11 | Native PDFKit simple two-column and deterministic wrapped Markdown/legacy approval fixtures passed. Approved, pending, excluded and missing evidence boundaries are covered by fixtures. Requested word limits are forwarded and clearly advisory. | Live approved, excluded, missing and conflicting evidence outputs and word counts remain unmeasured. |
| AT-12 and AT-13 | Lifecycle and recovery regressions passed. The physical adapter probe repeatedly stopped and reopened a source. | Native post-Stop network sends and live interruption/recovery remain unmeasured. |
| AT-16 | The owner confirmed that no remote endpoint is currently available. | Blocked. No 90-minute run on this revision. |
| Fresh holdout and latency | 100 new annotated synthetic turns, rendered to 30 audio tracks. The fixture was frozen before corrections. | Live question quality, duplicates, premature answers and speech-end to displayed text and completion remain unmeasured. |

The local container-based Linux attempt could not connect to the Docker daemon. The hosted Linux job supplies the Linux verification. Native UI automation timed out during the correction session. The physical output adapter probe ran independently.

## Earlier milestone evidence

## Test environment and artifact

| Item | Evidence |
|---|---|
| Approved baseline | `6fdcc4b3e35c489499e4f1014cd69f5ce98167ed` on `feature/m10-2-final-development`. Hosted baseline [run 45547625533](https://github.com/Tekie79/Mock-interview/actions/runs/45547625533) passed 94 Linux, 103 macOS 15 and 104 macOS 26 tests and both unsigned packages. |
| Local host | Mac17,8 MacBook Pro, Apple M5 Pro, 18 cores, 48 GiB, arm64, macOS 26.3.2 (25D2150). Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5. Xcode was installed during qualification. |
| Local portable baseline | `./scripts/build.sh` and `./scripts/test.sh` with an isolated scratch path passed on the Xcode toolchain with 104 XCTest passes, zero failures and zero skips. Pinned Swift 6.2.3 Noble arm64 container baseline passed 94 tests, zero failures. |
| Unsigned native package | `./scripts/package-macos.sh <derived-data-path>` built arm64 and x86_64, both with minimum macOS 14.2. Verified executable, bundle type, unsigned package and three privacy descriptions. The native window retest package had executable SHA-256 `f0fbd0c664b3aa8f66a83e6f1fd2edd56682b0361e4add6f0b498c3aff5f9e5f`. |
| Local post-fix tests and bundle | 106 XCTest passes, zero failures and zero skips on Xcode Swift 6.3.3. Release executable SHA-256 for the first reviewed M11 commit `56382ef9606c6615e9a5e8bfd6f3e2344e1c5725` is `c4e87c419a67fba9e4efe7f879e1cf77f110fb1096e8a54c2709b76d88649f7e`. |
| Formatted answer and Keychain startup build | Local Xcode Swift 6.3.3 passed 107 XCTest cases with zero failures or skips. The unsigned Release executable SHA-256 is `ab82151aa6f10fe985fc1222dbe0f8961f28c470dcdc5b56ce15981640f89080`. |
| Answer types and custom length | 112 local XCTest passes, zero failures and skips. The unsigned app launched with the existing provider item status visible and an editable Word limit. Release executable SHA-256 `6b270e259764755a68633ac99ff9f3d250d4db83a0332ffdc7d93e9f981fe2af`. |
| Regression commands | `./scripts/build.sh`, `./scripts/test.sh`, `./scripts/package-macos.sh`, `python3 Tests/Fixtures/m11/render.py` and `git diff --check`. The review PR records the exact revision and final hosted matrix against that revision. |

The SwiftPM runs emitted five search-path diagnostics related to missing pkg-config/SQLite/zlib metadata on the Mac. The SDK libraries linked and tests passed. The native window retest package emitted one App Intents metadata extraction warning and zero Swift or Clang compiler warnings. Packaging is unsigned.

## AT-01 through AT-18 on earlier M11 revisions

A scenario earns **Passed** only within its specified layer. Native runtime, provider adapter and deterministic results are identified separately. These observations are historical. The current correction evidence is recorded above.

| ID | Status | Observed evidence or missing evidence |
|---|---|---|
| AT-01 | Passed | The selected Zoom process yielded live remote transcription, completed automatic cards and continued listening after answers. Unlabeled Q&A smoke has no precision or recall denominator. |
| AT-02 | Not tested | Candidate role fixtures and all held-out candidate text cases generated zero answers. The independent physical microphone case requires an end-to-end run. |
| AT-03 | Passed | All 10 imperative held-out text cases reached accepted-question creation, without relying on a question mark. |
| AT-04 | Passed | The corrected held-out text recheck produced zero false activations in 20 greeting/logistics examples, down from eight. Production PCM accuracy is tracked separately. |
| AT-05 | Not tested | All 10 marked incomplete text fragments produced no early card and all 10 continuations were accepted in the initial text run. The native real-audio pause boundary remains open. |
| AT-06 | Passed | The final text retest linked 10 of 10 held-out follow-ups as labeled. The first text run missed one follow-up. |
| AT-07 | Not tested | The classifier accepted all 10 multipart turns in the initial text run. Verify that actual rendered answers address all substantive parts. |
| AT-08 | Passed | `RealtimeTests` reorders final events and `SessionIntegrationTests` delivers an exact duplicate final and asserts one answer. `ElevenLabsTests` covers delayed, reordered and duplicate final companions. |
| AT-09 | Passed | The latest held-out text retest created ten distinct repeat cards and linked all ten as labeled. Earlier runs varied, and deterministic coverage verifies verbatim repeat linkage across an unrelated intervening question. |
| AT-10 | Passed | Deterministic lifecycle tests superseded a running answer, guarded stale callbacks and asserted capture independence. The native interactive combination has separate coverage below. |
| AT-11 | Not tested | Deterministic grounding cases validate the prompt and approved-fact boundary. Live missing-fact and conflict answer review is still required. |
| AT-12 | Not tested | Native replay switched to Paused, then Listening, then Stopped. Stopped diagnostics reported zero connected sources. Deterministic tests cover cancellation and late callbacks. Exact network sends after the native Stop acknowledgment remain unmeasured. |
| AT-13 | Not tested | Deterministic recovery, fresh epoch, timeout and degraded-state tests passed. A live connection interruption and recovery run remains open. |
| AT-14 | Passed | Native synthetic replay completed with the default save toggle off. Read-only SQLite inspection afterward returned one pre-existing Solo Practice entry and zero interview rows. The exportable diagnostics contained only states, timings and counters. No persistent captured audio was observed. |
| AT-15 | Passed | In the native UI, missing provider credentials blocked startup and returned a Settings action without disclosing credentials. A live embeddings call with a synthetic invalid key returned the expected redacted error. Provider fixtures cover other invalid-key paths. |
| AT-16 | Blocked | The labeled-track attempt stopped after two minutes. The owner-provided Zoom Q&A run ended at 11 minutes 45 seconds. The 90-minute stability gate remains open. |
| AT-17 | Passed | Deterministic synthetic PCM replay exercised capture, transcript, role, classification, answer and diagnostics without live keys. |
| AT-18 | Not tested | All 10 unknown-role held-out text cases yielded zero accepted questions. Deterministic mixed diarization rejects unmapped speakers and resets mappings after a new epoch. The mixed-microphone hardware scenario remains open. |

## Earlier native interaction record

| Status | Observation |
|---|---|
| Passed | Actual app opened the workspace and displayed a compact answer panel. The keyboard shortcut opened Compact. Two post-fix Compact → Expand cycles returned to the same workspace AX window identity. The Always on Top checkbox toggled. |
| Passed | Settings displayed separate secure key fields and connection controls. The alternative-cloud preset independently selected Deepgram Nova-3 and Anthropic text providers. Keys were supplied locally by the owner. No credential contents were captured. |
| Passed | App created a synthetic profile, accepted pasted résumé text and let the tester add a pending synthetic fact. Native History/Review opened with no saved interviews. Solo Practice accepted a typed sample and stored one exercise after explicit save. |
| Passed | The subsequent unsigned bundle launched with the existing explicit device setting, synthetic profile and saved exercise. SQLite returned `quick_check=ok`. The app support directory was `0700` and the database was `0600`. |
| Passed | Native PCM replay reached one final and a completed automatic answer. A separate manual question showed the Manual answer label and went from Generating to Complete. Previous answer selected the automatic answer. Pin changed to Unpin. Regenerate started a new stream and Cancel moved it to Cancelled. |
| Passed | Stopped replay diagnostics showed zero connections, reconnects, dropped audio chunks and question queue overflows, one final, two question cards, one completed answer and 407 input/185 output tokens. |
| Passed | Local provider probe imported synthetic TXT job description, Markdown, DOCX and PDF via the production document reader, indexed one approved fact and excluded pending/rejected claims. The disposable profile and documents cascaded on deletion. Three streamed grounding probes showed no prohibited marker. This is a narrow marker check, with ambiguous and unsupported claim review still open. |
| Passed | The answer layout rendered a heading, bold phrase, numbered steps and code in a synthetic SwiftUI preview at 450 points. The updated unsigned product bundle opened to an idle workspace. Settings recognized two existing Keychain items without asking to read their values on launch. |
| Passed | The typed renderer displayed the four STAR sections, turned plain sentences into Talking points, and showed Technical sections with a fenced code example. The unsigned app's Word limit accepted the exact value 60 and the previous value was restored. A controlled generator verified the custom limit, format and grounding context in a regenerated answer request. |
| Not tested | Cross-app z-order, VoiceOver, live response-format changes and copy in the updated bundle, signed installation and clean-host upgrade. |

Sanitized UI observations used the accessibility tree and visual inspection of the workspace, Compact, settings and Solo Practice. Private meeting details, credentials and audio recordings are excluded from the evidence.
