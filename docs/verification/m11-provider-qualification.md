# M11 provider qualification

## Revised OpenAI production scope

The current qualification covers `gpt-live-transcribe`, GPT-6 Luna at `none` for structured classification and optional asynchronous session summarization, GPT-6.2 Sol at `low` for streaming suggestions and evaluation, and `text-embedding-3-small` for semantic lookup. Use the native application's Keychain flow and record benchmark and smoke results per revision on [draft PR #3](https://github.com/Tekie79/Mock-interview/pull/3). Provider timing summaries measure the API request through text or completion. The rendered latency gate requires a separate capture and display measurement.

Live Scribe strategy, audio drain and benchmarks below are historical context for an optional adapter. Neither those results nor live Deepgram or Anthropic are blockers for OpenAI. The app identifies configurations outside the revised scope. ChatGPT sign-in remains eligibility-gated.

## Release candidate after f726664

| Configuration | RC observation and qualification |
|---|---|
| Apple SpeechAnalyzer | On-device en-US file recognition completed on 30 fresh holdout tracks with 126 finals and 3.60% word error rate across isolated tracks. The earlier classic Apple Speech and SpeechAnalyzer application smoke remains historical. Capture permissions and long-running rollover remain open. |
| ElevenLabs `scribe_v3_live` · Manual | Fixtures passed. Native matched retest retained 10 finals and reported 3 unresolved voiced ranges, 5,760 samples (240 ms) and 3 pending commits. Open. |
| ElevenLabs `scribe_v3_live` · VAD | Fixtures passed. Native matched retest retained 10 finals and reported 2 unresolved ranges, 3,456 samples (144 ms) and 1 pending commit. Open. |
| ElevenLabs `scribe_v3_live` · Semantic turn | Fixtures passed. Native matched retest retained 10 finals and reported 3 unresolved ranges, 4,800 samples (200 ms) and 1 pending commit. Open. |
| ElevenLabs `scribe_v2_realtime` | Prior sentinel smoke only. Live multi-turn drain remains unqualified. |
| OpenAI transcription, structured classification, streamed answers and optional embeddings | Account-specific smoke described below. The recommended comparative evaluation is Luna `none` for classification and Luna `none` vs Sol `low` for streaming answers. Current repeated model latency, grounding and connection recovery remain open. |
| Deepgram and Anthropic | The owner supplied no test credentials. Fixture behavior is covered. Deepgram diarization and Anthropic live responses remain unqualified. |
| ChatGPT subscription | Unavailable in Settings until official distribution eligibility and activation details are confirmed. |

The Scribe coverage correction allows at most 60 ms of slack at each original voiced-span edge when the final intersects at least half of the span. The existing 20 ms word handoff applies, and coverage preserves a larger interior gap and unrelated leading or trailing audio. At incomplete drain the adapter logs strategy and bounded counts for pending ranges, samples, commits, companions and partial state. The native runs used unsigned revision `bb7269b` and the identical 59.3826-second PCM fingerprint below. The replay was set to mixed manual answers to isolate transcription. All three runs completed with no pending textual partials or final companions, and all three correctly failed the graceful completion gate. The timestamp versus voiced-range discrepancy remains unresolved. The logs establish residual audio and unacknowledged commits even after the edge correction. [Event reference](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference)

The owner estimated US$2 of prior usage against the cumulative US$10 cap. The matched comparison streamed 178.148 seconds of synthetic PCM to ElevenLabs, plus a short connectivity replay stopped after 21 seconds in the UI. Automatic text generation was disabled in mixed manual mode. The amount actually charged remains visible in the provider accounts.

Live provider smoke inputs in this report are synthetic. Keys are entered by the owner in the application's separate secure fields under **Settings → Accounts and billing**. The presence of a Keychain item is setup evidence. Provider availability and accepted model IDs require successful tests against the selected account. The table and PCM results below predate the latest correction.

| Service | Exact model or configuration | Status | Observed scope |
|---|---|---|---|
| Apple Speech | English (US), strictly on device | Passed | Native readiness succeeded. The Mac had an installed en-US SpeechAnalyzer asset and classic on-device support. Source replay produced 33 partials and 3 finals in SpeechAnalyzer and 23 partials and 1 final in classic with a vocabulary hint. Both paths recognized all 3 synthetic sentinels. |
| OpenAI API | `gpt-live-transcribe` with English and a vocabulary hint | Passed | Real PCM, readiness, partial/final lifecycle and graceful drain. 23 partials, 1 final and 3 of 3 sentinels. The final had no provider audio range. Model alternatives and live network recovery remain unqualified. |
| OpenAI API | `gpt-4.1-mini`, classification and answers | Passed | Structured classifier output and completed stream with 59 nonblank deltas, 163 input and 60 output tokens in the initial smoke. Subject the independent semantic gate to the benchmark results. |
| OpenAI API | `text-embedding-3-small` | Passed | Real indexing of one confirmed fact and relevant hybrid retrieval. Pending and rejected claims were excluded. A synthetic invalid key returned the expected redacted authentication error. |
| ElevenLabs | `scribe_v3_live` and `scribe_v2_realtime` | Passed | Five live model/strategy smoke calls returned one timestamped final each and all 3 sentinels. Live multi-utterance differences are recorded in the benchmark. Recovery and account usage reconciliation remain open. |
| Deepgram | `nova-3` | Blocked | Missing test key. The alternative-cloud preset selected Nova-3 and the native connection check showed the missing credential. Mock transport coverage passed. |
| Anthropic API | `claude-haiku-4-5` | Blocked | Missing test key. The alternative-cloud preset selected Anthropic independently for classification and answers. Mock transport coverage passed. |
| ChatGPT plan | Official eligible account and model | Blocked | Authorization was unavailable in native Settings. Synthetic OAuth and account/billing isolation regressions passed. |

## Live PCM smoke

The local harness sent synthetic PCM through the production recognition channel with English selected. Each row ended with one nonempty final. Zero gaps or reported drops were observed in these short runs.

| Model | Commit strategy | Partial count | Finals with mapped audio range | Samples submitted locally at 24 kHz | Whole run (s) |
|---|---|---:|---:|---:|---:|
| OpenAI `gpt-live-transcribe` | Client-managed | 23 | 0 | 167,520 | 9.499 |
| ElevenLabs `scribe_v3_live` | Semantic turn | 21 | 1 | 183,282 | 8.983 |
| ElevenLabs `scribe_v3_live` | VAD | 21 | 1 | 183,282 | 9.161 |
| ElevenLabs `scribe_v3_live` | Manual | 20 | 1 | 183,282 | 8.991 |
| ElevenLabs `scribe_v2_realtime` | VAD | 7 | 1 | 183,282 | 8.928 |
| ElevenLabs `scribe_v2_realtime` | Manual | 7 | 1 | 183,282 | 8.776 |

Provider wall time here includes stream setup and real-paced replay. Apple's classic and SpeechAnalyzer paths used the same input in a separately bundled native runtime probe. The probe exercised both engines with an installed asset and strict mode. Permission denial/re-grant and sustained rollover need more tests.

OpenAI lists January 14, 2027 as the shutdown date for `gpt-4.1-mini-2025-04-14`, the model snapshot relevant to the existing `gpt-4.1-mini` defaults. Confirm account availability in Settings. Qualify the documented replacement independently before relying on it for release. [OpenAI deprecations](https://developers.openai.com/api/docs/deprecations)

## Qualification after 41c243a

| Check | Status | Evidence and remaining work |
|---|---|---|
| Scribe v3 Live final association | Offline pass | Regression tests cover plain/timed pairs with punctuation drift and later timed finals that precede an earlier companion. Timed coverage still has bounded tolerance and unresolved speech remains incomplete. |
| Scribe v3 Live manual, VAD and semantic turn | Blocked | The earlier single-final sentinel smoke exercised all three modes. The multi-turn run varied transcription provider as well as strategy. Compare the three strategies on identical independently annotated PCM and score segment boundaries, downstream classification, premature cards and repeat handling. Manual commits follow the client endpoint, VAD follows audio inactivity, and semantic turn uses provider turn prediction with silence fallback. Speaker identity requires separate diarization evidence. [ElevenLabs strategy contract](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies) |
| OpenAI model and effort matrix | Blocked | The configured GPT-6 Luna, GPT-6.2 Sol and GPT-5.4 mini choices have request and capability fixtures. Exercise each supported effort for classification and streaming answers on the actual account, and measure usable-output latency before promoting a default. OpenAI's published replacement for the dated GPT-4.1 mini snapshot is GPT-6 Luna. The current undated defaults were retained. [Model comparison](https://developers.openai.com/api/docs/models/compare) · [Deprecations](https://developers.openai.com/api/docs/deprecations) |
| Live profile grounding and length | Blocked | Test approved, excluded, missing and conflicting evidence in streamed answers. The requested word limit is advisory and the UI says output can exceed it. Actual word counts were not collected in this run. |
| Deepgram and Anthropic | Blocked | The noninteractive development probe returned item-not-found (`-25300`) for these providers. Existing mocked coverage passed. |
| OpenAI and ElevenLabs credentials | Blocked for standalone live probe | Noninteractive local access returned authentication-failed (`-25293`) for the existing entries. The probe worked without prompting after interaction was disabled for the helper process. No credential content was captured. |

The correction sent zero billable provider requests. Earlier historical spend remains subject to provider statements and the owner's approved US$10 total. The 90-minute run did not start because no remote endpoint was available.

## Native authorization after b2946d6

Mock Interview displayed OpenAI and ElevenLabs items as present in Keychain. The owner approved the OS authorization prompt locally. The native Settings checks on the reviewed bundle acknowledged OpenAI `gpt-live-transcribe`, returned a structured answerable decision from GPT-6 Luna at `none`, and completed an answer stream from GPT-6.2 Sol at `low`. These three probes were single synthetic requests and had no clean latency sample. The application loaded credentials through its standard path. The newer unsigned build required its own OS authorization.

OpenAI publishes Luna at `none`, `low`, `medium`, `high`, `xhigh` and `max` and Sol at `low` through `max`. Both advertise structured outputs and streaming. The app allows only explicit `none` or `low` where supported in classification, to fit the live deadline, and exposes the supported reasoning efforts for answers. [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) · [GPT-6.2 Sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol)

The continuation bundle returned structured decisions from Luna `low` and Sol `low`. Native synthetic answer streams completed at all explicit answer efforts, six for Luna and five for Sol. Later Settings observations bracketed the Sol `low` structured decision between 0.56 and 3.95 s and the Luna `none` stream completion between 0.60 and 3.99 s after click. These bounds include UI automation and polling. The reviewed bundle also passed Luna `none` classification. Full latency distributions by model and effort still need repeated samples.

A native manual answer using the isolated synthetic practice profile exposed **Profile evidence** and described the implemented retry worker, excluded database-platform ownership, and stated that it had no verified impact numbers. The app reported 617 input and 31 output tokens and 911 ms from request to first text token. This covers approved evidence, an explicit ownership limitation and a missing metric in one live answer. Conflicting and separately excluded facts remain open.

### Scribe v3 Live strategy comparison

The app replayed the same 59.3826-second single-source PCM in each mode. Input was the ten annotated turns of frozen scene 01, with overlap removed for this comparison and 1.7 seconds between clips except the 1.45-second designated continuation. PCM SHA-256 `a027b55709e76c5a98df57fa95294c581f6fade8424b36529de501e2242c069f`. All runs used English, endpoint silence 0.65 s, question wait zero, and GPT-6 Luna `none` for classification and answers. The route designated the single mixed input as interviewer, so the reference unknown voice reached the classifier.

| Scribe strategy | Finals / mapped cues | Completed cards | Estimated endpoint to SwiftUI acknowledgment p50 / max | Estimated endpoint to terminal p50 / max | Replay drain |
|---|---:|---:|---:|---:|---|
| Manual | 10 / 10 | 5 | 2,950 / 3,461 ms | 3,741 / 4,009 ms | Unconfirmed audio |
| VAD | 10 / 10 | 5 | 3,355 / 4,194 ms | 3,854 / 5,070 ms | Unconfirmed audio |
| Semantic turn | 10 / 10 | 5 | 3,457 / 3,783 ms | 4,117 / 4,504 ms | Unconfirmed audio |

Every strategy answered the four labeled questions and also answered the unknown speaker's question. Each had 80% card precision, 100% recall, and zero duplicate or premature cards in this one scene. Synced transcript provenance associated each card with its labeled turn. All three reported unresolved audio at graceful completion. Manual timing used local speech estimation. VAD and semantic-turn timing mapped provider ranges to capture time. The visible timing is the application's SwiftUI acknowledgment and does not measure screen refresh or independent acoustic endpoint. This short comparison provides no basis to select a global default. [Commit strategy contract](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies)

### Permission reuse

The final correction serializes credential reads and writes off the UI thread and caches an authorized read per account for the running process. Saving or removing a key updates that cache only after successful Keychain persistence. On first provider use after launch, macOS can authorize the Keychain read silently when the existing grant and app identity match. The unsigned development builds used during qualification have separate binaries and can prompt again. [Apple Keychain ACLs](https://developer.apple.com/documentation/security/access-control-lists) · [macOS designated requirements](https://developer.apple.com/library/archive/technotes/tn2206/)

## Spending

The owner approved a **US$10 total test usage limit**. Estimated upper workload before retries and account pricing is approximately **US$5.17**. It assumes 220 OpenAI audio minutes at $0.017/min, 50 ElevenLabs audio minutes including a $0.05/hour vocabulary add-on at a total $0.27/hour, 50 Deepgram Nova-3 multilingual minutes at $0.0058/min, and 300,000 input plus 75,000 output tokens for each text provider at published rates for the listed baseline models. Both channels count toward audio minutes. Consult account billing for actual usage. This estimate is neither an invoice nor a provider-enforced spending limit. [OpenAI pricing](https://developers.openai.com/api/docs/pricing) · [ElevenLabs pricing](https://elevenlabs.io/pricing/api) · [Deepgram pricing](https://deepgram.com/pricing) · [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)

## ChatGPT activation

Sign in with ChatGPT is implemented behind the eligibility restriction. For an open-source/local release, the owner must document that this distribution qualifies under OpenAI's preview and select a license if distributing it as open source. Confirm uncertain eligibility with OpenAI. For a paid or remotely hosted release, the owner must submit the interest form and obtain OpenAI's approval and approved integration details. A reviewed change can then enable the gate and qualify browser callback, identity, switching, refresh, revocation, model discovery, answer streaming and usage limits with an eligible account. Use the separate API credentials only when those API providers are selected explicitly. [Official preview](https://developers.openai.com/siwc/token-sharing-open-source) · [Interest form](https://openai.com/form/sign-in-with-chatgpt-interest/) · [Repository provider policy](../provider-compatibility.md)
