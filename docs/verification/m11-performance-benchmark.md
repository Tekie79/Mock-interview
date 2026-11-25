# M11 performance benchmark

## Acceptance correction benchmark

The fresh holdout was frozen before tuning. `qualification.jsonl` contains 100 distinct labeled turns in 10 scenarios, with 40 accepts, 50 ignores and 10 waits. The renderer produced 30 PCM tracks and 10 insertion-label files using `python3 Tests/Fixtures/m11/render.py --render qualification --output <directory>`. SHA-256 of the frozen labels is `5dd9e1f824c83b5a4299917db29d92d776ec25cf1f9095b26db013688d749f3f`. Earlier text and audio retests serve as regression data. The new audio has not been scored against live providers. Before using it for the latency gate, independently mark actual acoustic speech ends.

### Human question-and-answer recording

The recorded diagnostic used the first 177 seconds of the Q&A excerpt from the May 1, 2024 Federal Reserve press conference. Nine windows were labeled from the published Q&A before classification. A continuous Apple transcription established an approximately eight- to nine-second difference between the published caption clock and the excerpt media clock. An initial misaligned run was discarded. Local SpeechAnalyzer transcribed the corrected windows. Production question gating then evaluated them with a permissive classifier fixture, which accepted everything it received. [Federal Reserve video](https://www.federalreserve.gov/monetarypolicy/fomcpresconf20240501.htm) · [Official transcript](https://www.federalreserve.gov/mediacenter/files/FOMCpresconf20240501.pdf)

| Expected turn | Windows | Passed to classifier | Blocked before classification |
|---|---:|---:|---:|
| Complete request | 3 | 3 | 0 |
| Spoken answer, incomplete setup or clarification | 6 | 2 | 4 |

All four ordinary answer windows were blocked. The incomplete setup and clarification reached the classifier. This measures preclassifier gating at 3/5 precision and 3/3 recall on nine windows. Because this recording informed the corrections, it now serves as a regression diagnostic. Live automatic-answer precision and recall, duplicate/premature counts, physical speaker-label accuracy and model latency remain unmeasured. The excerpt SHA-256 is `8f4b966f7c1138f78589e53495b246270e1d0ea5ab2df2d53fc311bdbbbaba22`. Evaluation time windows are relative to the excerpt: positives 11.94–21.59, 123.00–126.24, 147.36–163.61 s; negatives 21.60–53.87, 60.60–79.01, 103.86–116.39, 118.60–120.95, 126.25–137.81, 163.62–176.90 s.

### Silence wait trade-off

`QuestionRoundTests` drove two requests separated by 750 ms of simulated quiet, with controlled provider finals and classifier. An early card means the first part reached classification before the second part arrived.

| Silence wait (s) | Final-to-eligibility wait (ms) | Early cards | Total cards | Result |
|---:|---:|---:|---:|---|
| 0 | 0 | 1 | 2 | Separate requests |
| 0.5 | 500 | 1 | 2 | Separate requests |
| 1 | 1,000 | 0 | 1 | Both requests in one round |
| 2 | 2,000 | 0 | 1 | Both requests in one round |

This measures the configured assembly gate with a virtual clock. Speech-end to first useful displayed text, completion latency and the trade-off on real paused speech still require annotated playback through the native workspace. The actual 90-minute remote run is blocked because no remote endpoint is available.

## Earlier benchmark runs

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

### Follow-up audio replay after classifier corrections

The next 100-turn production replay scored the same recordings with the same model split. OpenAI produced 24 completed cards, 23 lexical matches to expected questions and one to an incomplete turn. ElevenLabs semantic turn produced 11 cards, of which 9 completed and 2 were streaming at cutoff. Five mapped to accepted labels, five to ignored labels and one to an incomplete turn. These counts use the same approximate mapping. The ElevenLabs replay gate remains open.

On the retest, classification p50/p95 was 1,446/2,447 ms for 24 completed OpenAI STT cards and 1,575/2,301 ms for nine completed ElevenLabs STT cards. Estimated endpoint to terminal p50/p95 was 4,179/5,136 ms and 4,213/4,891 ms respectively. Across both configurations the harness reported zero reconnects, zero drops and zero question queue overflows. All ten sessions drained to zero connected sources after Stop.

## Zoom runtime smoke

The 120-second process-scoped trial used `gpt-live-transcribe` and `gpt-4.1-mini` with the candidate mic and local retention off. There were 8 final segments, 5 completed answers, 0 reconnects, 0 reported dropped chunks, 0 question queue overflows and 0 connected sources after Stop. Recognition reported 32 seconds. The app submitted 26 PCM seconds locally, reflecting local speech gating. Completed streams used 1,249 input tokens and 404 output tokens. During the trial, four `ps` observations were 35.0–61.8% CPU and 217,136–224,128 KiB RSS.

The last answer showed estimated local endpoint to SwiftUI visibility of 4,202 ms and estimated endpoint to terminal of 4,913 ms. These are single-answer diagnostics based on the app's clock correlations. The source was not aligned to an independent annotation, so this trial provides no acceptance percentile. The run stopped after two minutes and is excluded from the 90-minute stability gate.

A supplemental 12-turn text probe alternated substantive questions and spoken answers on one interviewer-designated source. With the latest utterance separated from the reference context, six expected positives yielded five acceptances and one timeout. Two of six negative examples still produced acceptances. The one-source Zoom Q&A test has no corresponding independent turn labels, so recorded automatic answer counts do not establish correctness. [Supplemental fixture](../../Tests/Fixtures/m11/zoom-qa.jsonl)

The live Q&A follow-up five-minute checkpoint reported 28 finalized segments, 16 completed automatic answers, 1 connected source and zero reconnects, drops or queue overflows. The app submitted 110 PCM seconds and the provider reported 124 recognition seconds. Completed answers used 4,628 input and 1,372 output tokens. Its latest local estimate was 2,884 ms to the SwiftUI visibility callback, a pipeline observation only. A separate credential-free OpenAI HTTPS probe connected in 20 ms and completed TLS in 43 ms on this host. This probe is not a Zoom RTT measurement.

The final held-out **text** retest using the separated latest utterance scored 50 true positives, 50 true negatives, zero false positives and zero false negatives. It resolved 10 follow-ups, 10 literal repeat links and all 10 two-part prompts as labeled. The supplemental single-source Q&A errors remain open, so these scores apply to this held-out text corpus.

The owner-provided Zoom Q&A follow-up stopped at 705 seconds. Final diagnostics reported 39 finals, 21 completed answers, zero connected sources, reconnects, dropped chunks or question queue overflows, 160 PCM seconds submitted, 180 provider-reported recognition seconds and 6,260 input plus 1,851 output tokens. Nineteen live samples after the resource sampler started showed 19.1–60.4% CPU and 132,576–175,376 KiB RSS. After Stop, the process had zero established TCP sockets and SQLite contained zero saved interview rows. The last answer diagnostic estimated 5,136 ms to the SwiftUI visibility callback and 6,306 ms to completion. There were no independently annotated latency or Q&A quality denominators for this source.
