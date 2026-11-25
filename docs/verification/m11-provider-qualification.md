# M11 provider qualification

All provider data in M11 is synthetic. Keys are entered by the owner in the application's separate secure fields under **Settings → Accounts and billing**. The presence of a Keychain item is setup evidence. Provider availability and accepted model IDs require successful tests against the selected account.

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

## Spending

The owner approved a **US$10 total test usage limit**. Estimated upper workload before retries and account pricing is approximately **US$5.17**. It assumes 220 OpenAI audio minutes at $0.017/min, 50 ElevenLabs audio minutes including a $0.05/hour vocabulary add-on at a total $0.27/hour, 50 Deepgram Nova-3 multilingual minutes at $0.0058/min, and 300,000 input plus 75,000 output tokens for each text provider at published rates for the listed baseline models. Both channels count toward audio minutes. Consult account billing for actual usage. This estimate is neither an invoice nor a provider-enforced spending limit. [OpenAI pricing](https://developers.openai.com/api/docs/pricing) · [ElevenLabs pricing](https://elevenlabs.io/pricing/api) · [Deepgram pricing](https://deepgram.com/pricing) · [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing)

## ChatGPT activation

Sign in with ChatGPT is implemented behind the eligibility restriction. For an open-source/local release, the owner must document that this distribution qualifies under OpenAI's preview and select a license if distributing it as open source. Confirm uncertain eligibility with OpenAI. For a paid or remotely hosted release, the owner must submit the interest form and obtain OpenAI's approval and approved integration details. A reviewed change can then enable the gate and qualify browser callback, identity, switching, refresh, revocation, model discovery, answer streaming and usage limits with an eligible account. Use the separate API credentials only when those API providers are selected explicitly. [Official preview](https://developers.openai.com/siwc/token-sharing-open-source) · [Interest form](https://openai.com/form/sign-in-with-chatgpt-interest/) · [Repository provider policy](../provider-compatibility.md)
