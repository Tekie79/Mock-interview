# M11 performance benchmark

The latency and stability gates remain open. The [requirements](../requirements.md) define thresholds at actual speech end and useful visible text.

## Corpus and first classifier run

The development split has 200 labeled synthetic turns in 20 recordings. The held-out split has 100 labeled turns in 10 separate recordings, including overlap, partial prompts, repeats and candidate/unknown questions. Cross-split normalized utterance text is disjoint. These synthetic voices and templated conversations give controlled layer coverage. Human speakers, acoustic conditions and annotator variation require additional evidence. [Corpus fixtures and render command](../../Tests/Fixtures/m11/README.md)

On the approved classifier, the live OpenAI API with `gpt-4.1-mini` received the 100 labeled **text turns** through the role gate and question detector. The negative class includes 40 ignore and 10 wait labels. There were no request errors surfaced by the classifier run. This run excludes acoustic segmentation and response rendering.

| Metric | Requirement | Initial observed result | Status |
|---|---:|---:|---|
| Held-out question precision | ≥95% | 49 true positives / 57 accepted = 85.96% | Failed |
| Held-out question recall | ≥90% | 49 / 50 = 98.00% | Passed on text |
| Premature answers | ≤5% | 0 / 10 explicit incomplete text turns. End-to-end audio percentage unavailable. | Not tested at acceptance layer |
| Duplicate automatic answers | ≤1% | Full audio denominator unavailable. Exact-event regression passed. | Not tested at acceptance layer |
| Exact duplicate event responses | Zero | No extra response in deterministic session replay | Passed |
| Deterministic candidate triggers | Zero | Zero in role fixtures and 0 / 10 candidate labels on live text classification | Passed |
| Unsupported personal claims | Zero | Deterministic prompt evidence boundary passed. Live generated claims need review. | Not tested at acceptance layer |
| First useful visible text | p50 ≤1.5 s, p95 ≤3.5 s | No independent speech-end to display observations | Not tested |
| Complete brief answer | p95 ≤7 s | No independent speech-end to completed-answer sample | Not tested |
| Continuous remote session | 90 min | No completed qualifying run | Blocked |

Eight false positives were split between greetings (four) and logistics (four). No unknown-role input activated a question. Nine of 10 follow-ups resolved as labeled. Ten intentional repeats each produced a distinct card and seven linked to the originally labeled reference.

## Resource and timing boundaries

The unsigned native window retest process used 174,688 KiB resident memory and showed 0.0% CPU on each of ten idle `ps` samples at two-second intervals. These observations describe idle behavior. Capture or provider-load resource growth requires a sustained run.

The live PCM smoke table reports whole-run wall time, submitted sample counts, overrun/gap observations and which final events had mapped audio ranges. Wall time includes readiness, replay and drain. It measures neither the speech endpoint delay nor first useful visible response. Local endpoint correlations and provider positions mapped to the capture clock are estimates. The application visibility acknowledgment is a SwiftUI callback. Measuring actual presentation requires an independently annotated speech-end and displayed-output record. [Provider smoke measurements](m11-provider-qualification.md)

## Text retest after the classifier correction

The same held-out split became a regression retest once its initial outcomes were reviewed. After the shared prompt and logistics and repeat corrections, the development split measured 100/100 true positives with 0/100 false positives. One corrected held-out retest measured 49/49 precision and 49/50 recall, with zero early cards from 10 incomplete turns, zero candidate/unknown triggers in 20 turns, and 10/10 multipart decisions with two parts. It linked eight repeats as labeled, mislinked one and could not score one missing antecedent. It resolved 9/10 follow-ups. A separate prompt-only retest measured 50/50 precision and 50/50 recall. Model variability and real input boundaries remain relevant.

## Production pipeline on held-out PCM

The initial audio run replayed all 100 labeled turns on aligned interviewer, candidate and unknown tracks into the production interview session. Each STT configuration used five distinct conversations and the same live OpenAI `gpt-4.1-mini` classifier and brief-answer generator. Simultaneous tracks are software sources and establish no acoustic cancellation performance.

| Observation | OpenAI `gpt-live-transcribe` | ElevenLabs `scribe_v3_live`, semantic turn |
|---|---:|---:|
| Conversations | 5 | 5 |
| Final transcript segments (interviewer / candidate / unknown) | 40 / 5 / 5 | 27 / 5 / 9 |
| Automatic cards (all had interviewer provenance) | 30 | 16 |
| Completed answers at observation cutoff | 27 | 13 |
| Generating at cutoff | 3 | 3 |
| Reported reconnects, dropped chunks and discarded questions | 0 / 0 / 0 | 0 / 0 / 0 |
| Locally submitted audio, summed across tracks | 226.86 s | 700.81 s |
| Provider-reported recognition duration | 252 s | Unavailable |
| Usage for completed streams, input / output tokens | 7,803 / 2,347 | 3,718 / 1,101 |

Coarse case matching used unique lexical-overlap assignments within each conversation. It matched 24 of 25 expected accepted labels for OpenAI and 8 of 25 for ElevenLabs. It assigned six other OpenAI cards and eight other ElevenLabs cards to negative labels, including two OpenAI cards resembling incomplete turns. A model may merge adjacent turns, and approximate matching cannot reliably disambiguate repeats, continuations or overlap. These are diagnostic counts. No audio precision, recall or duplicate percentage is credited as acceptance evidence.

### Stage timings from completed answers, milliseconds

| Metric | OpenAI sample count, p50 / p95 | ElevenLabs sample count, p50 / p95 |
|---|---:|---:|
| Commit to final | 27, 451 / 616 | Unavailable in this mode |
| Classification | 27, 1,656 / 2,505 | 13, 1,466 / 2,315 |
| Retrieval (empty synthetic knowledge) | 27, 0 / 0 | 13, 0 / 0 |
| Request to first token | 27, 492 / 596 | 13, 581 / 690 |
| Estimated endpoint to terminal | 27, 4,425 / 5,333 | 13, 4,216 / 4,962 |

Nearest-rank percentiles use successful completed cards. Six generating cards were outside these percentiles and remain in the table. No live provider error or overrun was reported. Local and provider-estimated endpoint clocks differ by adapter. No SwiftUI display acknowledgment or photometric time was captured by this headless harness.
