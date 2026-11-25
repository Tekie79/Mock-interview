# M11 final acceptance

**Release qualification remains open.** Native packaging and selected provider and hardware paths worked. The corrected held-out text run met text-level precision and recall. The audio-level gate is separate. A real 90-minute remote run and independently annotated visible-answer timings are required for release. See the [benchmark](m11-performance-benchmark.md), [provider results](m11-provider-qualification.md), [audio compatibility](m11-audio-compatibility.md) and [defects](m11-defect-register.md).

## Test environment and artifact

| Item | Evidence |
|---|---|
| Approved baseline | `6fdcc4b3e35c489499e4f1014cd69f5ce98167ed` on `feature/m10-2-final-development`. Hosted baseline [run 45547625533](https://github.com/Tekie79/Mock-interview/actions/runs/45547625533) passed 94 Linux, 103 macOS 15 and 104 macOS 26 tests and both unsigned packages. |
| Local host | Mac17,8 MacBook Pro, Apple M5 Pro, 18 cores, 48 GiB, arm64, macOS 26.3.2 (25D2150). Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5. Xcode was installed during qualification. |
| Local portable baseline | `./scripts/build.sh` and `./scripts/test.sh` with an isolated scratch path passed on the Xcode toolchain with 104 XCTest passes, zero failures and zero skips. Pinned Swift 6.2.3 Noble arm64 container baseline passed 94 tests, zero failures. |
| Unsigned native package | `./scripts/package-macos.sh <derived-data-path>` built arm64 and x86_64, both with minimum macOS 14.2. Verified executable, bundle type, unsigned package and three privacy descriptions. The native window retest package had executable SHA-256 `f0fbd0c664b3aa8f66a83e6f1fd2edd56682b0361e4add6f0b498c3aff5f9e5f`. |
| Local post-fix tests and bundle | 106 XCTest passes, zero failures and zero skips on Xcode Swift 6.3.3. Release executable SHA-256 for the first reviewed M11 commit `56382ef9606c6615e9a5e8bfd6f3e2344e1c5725` is `c4e87c419a67fba9e4efe7f879e1cf77f110fb1096e8a54c2709b76d88649f7e`. |
| Formatted answer and Keychain startup build | Local Xcode Swift 6.3.3 passed 107 XCTest cases with zero failures or skips. The unsigned Release executable SHA-256 is `ab82151aa6f10fe985fc1222dbe0f8961f28c470dcdc5b56ce15981640f89080`. |
| Regression commands | `./scripts/build.sh`, `./scripts/test.sh`, `./scripts/package-macos.sh`, `python3 Tests/Fixtures/m11/render.py` and `git diff --check`. The review PR records the exact revision and final hosted matrix against that revision. |

The SwiftPM runs emitted five search-path diagnostics related to missing pkg-config/SQLite/zlib metadata on the Mac. The SDK libraries linked and tests passed. The native window retest package emitted one App Intents metadata extraction warning and zero Swift or Clang compiler warnings. Packaging is unsigned.

## AT-01 through AT-18

A scenario earns **Passed** only within its specified layer. Native runtime, provider adapter and deterministic results are identified separately.

| ID | Status | Observed evidence or missing evidence |
|---|---|---|
| AT-01 | Passed | The selected Zoom process yielded live remote transcription, completed automatic cards and continued listening after answers. Unlabeled Q&A smoke has no precision or recall denominator. |
| AT-02 | Not tested | Candidate role fixtures and all held-out candidate text cases generated zero answers. The independent physical microphone case requires an end-to-end run. |
| AT-03 | Passed | All 10 imperative held-out text cases reached accepted-question creation, without relying on a question mark. |
| AT-04 | Passed | The corrected held-out text recheck produced zero false activations in 20 greeting/logistics examples, down from eight. Production PCM accuracy is tracked separately. |
| AT-05 | Not tested | All 10 marked incomplete text fragments produced no early card and all 10 continuations were accepted in the initial text run. The native real-audio pause boundary remains open. |
| AT-06 | Failed | Nine of 10 held-out follow-ups were accepted and linked to the expected prior question. One produced no question or clarification. |
| AT-07 | Not tested | The classifier accepted all 10 multipart turns in the initial text run. Verify that actual rendered answers address all substantive parts. |
| AT-08 | Passed | `RealtimeTests` reorders final events and `SessionIntegrationTests` delivers an exact duplicate final and asserts one answer. `ElevenLabsTests` covers delayed, reordered and duplicate final companions. |
| AT-09 | Failed | All 10 held-out literal repeats produced a new question. The corrected run linked eight, mislinked one and could not score one because its antecedent was missed. |
| AT-10 | Passed | Deterministic lifecycle tests superseded a running answer, guarded stale callbacks and asserted capture independence. The native interactive combination has separate coverage below. |
| AT-11 | Not tested | Deterministic grounding cases validate the prompt and approved-fact boundary. Live missing-fact and conflict answer review is still required. |
| AT-12 | Not tested | Native replay switched to Paused, then Listening, then Stopped. Stopped diagnostics reported zero connected sources. Deterministic tests cover cancellation and late callbacks. Exact network sends after the native Stop acknowledgment remain unmeasured. |
| AT-13 | Not tested | Deterministic recovery, fresh epoch, timeout and degraded-state tests passed. A live connection interruption and recovery run remains open. |
| AT-14 | Passed | Native synthetic replay completed with the default save toggle off. Read-only SQLite inspection afterward returned one pre-existing Solo Practice entry and zero interview rows. The exportable diagnostics contained only states, timings and counters. No persistent captured audio was observed. |
| AT-15 | Passed | In the native UI, missing provider credentials blocked startup and returned a Settings action without disclosing credentials. A live embeddings call with a synthetic invalid key returned the expected redacted error. Provider fixtures cover other invalid-key paths. |
| AT-16 | Blocked | The labeled-track attempt stopped after two minutes. The owner-provided Zoom Q&A source exercised the product separately. No completed 90-minute qualification is credited. |
| AT-17 | Passed | Deterministic synthetic PCM replay exercised capture, transcript, role, classification, answer and diagnostics without live keys. |
| AT-18 | Not tested | All 10 unknown-role held-out text cases yielded zero accepted questions. Deterministic mixed diarization rejects unmapped speakers and resets mappings after a new epoch. The mixed-microphone hardware scenario remains open. |

## Native interaction record

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
| Not tested | Cross-app z-order, VoiceOver, live response-format changes and copy in the updated bundle, signed installation and clean-host upgrade. |

Sanitized UI observations used the accessibility tree and visual inspection of the workspace, Compact, settings and Solo Practice. Private meeting details, credentials and audio recordings are excluded from the evidence.
