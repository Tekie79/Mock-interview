# M11 performance benchmark

## Release candidate after f726664

| Experiment | Results | Boundary |
|---|---|---|
| Freeze the 100-turn starvation case before correction | With a 550 ms virtual cadence and a one-second wait, `f726664` retained 100/100 finals, recovered 0/40 labeled requests and reported a queue discard. The RC retained 100/100 finals, recovered 40/40 labeled requests and reported no discard. | Identical frozen text, virtual clock and oracle classifier. Counts are labeled question parts and measure assembly recall. The earlier native attempt below retained 95 finals. |
| Silence and processing | The recorded human Q&A replay combined both parts at a 750 ms gap with 1,000 and 2,000 ms waits. At a 1,500 ms gap only 2,000 ms combined them. An endpoint 800 ms before final delivery leaves 200 ms of a one-second configured wait in the virtual clock test. | Recorded audio with controlled provider finals. The one-second gap result was also reproduced deterministically. No RC independently observed screen timing. |
| Fresh audio holdout | 100 cues, 40 accept, 50 ignore and 10 wait, in ten new scenes. Thirty separately routed macOS TTS tracks rendered with six English voices, five rates and overlapping insertions. | `rc-holdout.jsonl` SHA-256 `9b3ef25876d2c2cc79b44dceb7cd457df386f01e4410484b28f59a10428977c5`. No audio-to-answer scoring of this holdout used for tuning. Human voices and independent acoustic endpoint annotation are still needed. |
| Local SpeechAnalyzer on the RC holdout | en-US, time-indexed progressive transcription, 30 isolated WAV files, 126 finals. Per scene and role, punctuation-insensitive word edit distance was 45/1,250 (3.60% WER). Interviewer 15/865 (1.73%), candidate 10/302 (3.31%), unknown 20/83 (24.10%). | At the Apple file API, with role tracks separated. Number forms are counted as written. No microphone, speaker diarization or answer generation in this run. |

The RC starts semantic evaluation from finalized packets bounded by source, speaker and epoch. A recent mapped speech endpoint credits observed silence. When the endpoint is unavailable, the quiet period begins at final arrival. The first RC build split the longer recorded multipart question at its initial hard deadline. The corrected eight-second hard deadline is independent of the quiet wait and admitted the continuation in the same probe. The long-speech regression verifies that raw speech cannot extend it past eight seconds. Packet size is capped at 64 segments and 16,000 UTF-8 bytes. An unresolved partial can be used manually. The deadline sends only previously finalized text for semantic evaluation. Diagnostics expose decisions and peak queue occupancy without dialogue.

| Silence wait | 750 ms gap, early / cards | Final to classifying last part | 1,500 ms gap, early / cards | Final to classifying last part |
|---:|---:|---:|---:|---:|
| 0 ms | 1 / 2 | 0 ms | 1 / 2 | 0 ms |
| 500 ms | 1 / 2 | 508 ms | 1 / 2 | 508 ms |
| 1,000 ms | 0 / 1 | 1,017 ms | 1 / 2 | 1,000 ms |
| 2,000 ms | 0 / 1 | 2,017 ms | 0 / 1 | 1,408 ms |

The eight-second cap shortened the last 2,000 ms case because the second part finalized late in the packet lifetime. These eight cases measure the detector input boundary, with fixed classification and generation fixtures. They cannot establish production premature-response rates.

The acceptance thresholds remain 1,500 ms p50 and 3,500 ms p95 to first useful visible text and 7,000 ms p95 to a complete brief answer. Prior SwiftUI acknowledgments and provider event timings estimate stage delays. No current displayed-latency distribution is available. No model or effort default was promoted on smoke evidence.

## Continuation after b2946d6

Installed Apple SpeechAnalyzer ran on all 30 separate qualification tracks on macOS 26.3.2. A nonblank final overlapping a cue by at least 80 ms counted as transcription coverage. Track-level WER uses word edit distance after case and punctuation normalization against the frozen text. There were 134 finals covering all 100 cues. Overlap establishes coverage, and a single final may cover multiple cues.

| Track role | Cues covered | Finals | Reference words | Word edits | WER |
|---|---:|---:|---:|---:|---:|
| Interviewer | 60/60 | 66 | 729 | 15 | 2.06% |
| Candidate | 30/30 | 58 | 560 | 12 | 2.14% |
| Unknown | 10/10 | 10 | 100 | 40 | 40.00% |
| Total | 100/100 | 134 | 1,389 | 67 | 4.82% |

This is an on-device transcription measurement for known, separate tracks. The per-track voices and word populations differ. Mixed-channel speaker attribution and final answer quality are separate checks.

### Native live replay of the frozen corpus

The rebuilt app replayed all 497.036 seconds of frozen audio as one interviewer-designated feed. The three aligned tracks were mixed within each scene with the original gaps and overlap. Replay SHA-256 `a60efe01f57247ae5d308cd197ecc9be4c5b4724a58b763b06f1e47863ff05c3`. General practice supplied no profile context. OpenAI `gpt-live-transcribe` and GPT-6 Luna at `none` for classification and answers were selected. The run used one second of additional silence waiting and lasted 537.15 seconds from Start through the post-replay Stop.

OpenAI returned 95 finals. Ordered word alignment matched at least three tokens for 99 of the 100 cues. The native workspace repeatedly reported that the question buffer was full, retained the transcript, and reached end of file. It produced 0 answer cards for 40 expected accepts, so observed card recall was 0%. Card precision and time to rendered text have no sample. This failed end-to-end configuration adds no evidence about model accuracy on the full split. Most 550 ms clip gaps were shorter than the configured wait, and the single designated source treated speech from every speaker as interviewer activity. This outcome is distinct from the independent Apple transcription result and from separately assigned speaker channels.

The retry kept the same PCM, provider models, attribution and profile settings and set additional wait to zero. It finished after 533.76 seconds with 95 finals and the same 99-cue alignment coverage. All 44 cards completed. The score used the retained automatic-answer transcript IDs, ordered word alignment, and the generated question parts for mixed cues.

| Metric | Zero additional wait |
|---|---:|
| Matched question recall | 40/40, 100% |
| Card precision | 40/44, 90.91% |
| Unknown-voice activations | 4 standalone cards and 3 extra parts in otherwise matching cards |
| Candidate-only false positives | 0 |
| Duplicate cards | 0 |
| Premature cards attributed solely to a wait cue | 0 |
| Completed answer usage | 33,360 input and 3,153 output tokens |

Stage times across the 44 completed automatic answers use the application's pipeline instrumentation. P95 uses nearest rank.

| Stage | p50 | p95 |
|---|---:|---:|
| Classification | 1,542 ms | 2,289 ms |
| Answer request to first text token | 755 ms | 3,561 ms |
| Estimated endpoint to SwiftUI acknowledgment | 3,564 ms | 6,296 ms |
| Estimated endpoint to terminal answer | 4,203 ms | 6,497 ms |

Card precision misses the 95% target, and the overlapping unknown voice polluted three accepted answers. The zero-wait retry isolates a timing trade-off on the native mixed feed. App timestamps use a local endpoint estimate and SwiftUI acknowledgment. The independent speech-end to useful displayed-text gate remains open.

### Recorded speech and controlled silence

Two parts of one recorded Federal Reserve question were cut at the Apple SpeechAnalyzer range boundaries of 9.00, 11.58 and 16.25 seconds relative to the recorded third question below. The app's production replay, transcription channel and question round controller processed the real spoken clips with inserted silences of 750 and 1,500 ms. The probe injected the Apple-transcribed final at each cut boundary and used fixed decision and generation fixtures. The metric runs from delivery of the second final to its classifier call. An early card entered classification before the second final.

| Wait (s) | 750 ms gap, early / cards | Final to classification (ms) | 1,500 ms gap, early / cards | Final to classification (ms) |
|---:|---:|---:|---:|---:|
| 0 | 1 / 2 | 0 | 1 / 2 | 0 |
| 0.5 | 1 / 2 | 503 | 1 / 2 | 510 |
| 1 | 0 / 1 | 1,003 | 1 / 2 | 1,010 |
| 2 | 0 / 1 | 2,021 | 0 / 1 | 2,003 |

The one-second setting joined both requests across a 750 ms pause and separated them across a 1,500 ms pause. The two-second setting joined both at both gaps. This eight-configuration probe measures the assembly layer on recorded speech with controlled segmentation. Independently annotated speech-end to first useful displayed text and completed-answer latency remain release gates.

### Endurance readiness

The reproducible local playback was built and verified as two 5,400-second tracks with 1,000 labeled cues per cue sheet. It uses the frozen 100-turn synthetic split repeated ten times for load. The owner confirmed that a second endpoint remains unavailable. The playback setup is ready, and AT-16 is still blocked. [Build and run instructions](../../Tests/Fixtures/m11/README.md#90-minute-remote-playback)

## Acceptance correction benchmark

The fresh holdout was frozen before tuning. `qualification.jsonl` contains 100 distinct labeled turns in 10 scenarios, with 40 accepts, 50 ignores and 10 waits. The renderer produced 30 PCM tracks and 10 insertion-label files using `python3 Tests/Fixtures/m11/render.py --render qualification --output <directory>`. SHA-256 of the frozen labels is `5dd9e1f824c83b5a4299917db29d92d776ec25cf1f9095b26db013688d749f3f`. Earlier text and audio retests serve as regression data. Before using the rendered corpus for the latency gate, independently mark actual acoustic speech ends.

### Human question-and-answer recording

The recorded diagnostic used the first 177 seconds of the Q&A excerpt from the May 1, 2024 Federal Reserve press conference. Nine windows were labeled from the published Q&A before classification. A continuous Apple transcription established an approximately eight- to nine-second difference between the published caption clock and the excerpt media clock. An initial misaligned run was discarded. Local SpeechAnalyzer transcribed the corrected windows. Production question gating then evaluated them with a permissive classifier fixture, which accepted everything it received. [Federal Reserve video](https://www.federalreserve.gov/monetarypolicy/fomcpresconf20240501.htm) · [Official transcript](https://www.federalreserve.gov/mediacenter/files/FOMCpresconf20240501.pdf)

| Expected turn | Windows | Passed to classifier | Blocked before classification |
|---|---:|---:|---:|
| Complete request | 3 | 3 | 0 |
| Spoken answer, incomplete setup or clarification | 6 | 2 | 4 |

On `b2946d6`, the former narration filter blocked all four ordinary answer windows. The incomplete setup and clarification reached the classifier. This historical preclassifier result was 3/5 precision and 3/3 recall on nine windows. The current detector delegates narration and ambiguities to semantic classification. This recording informed the earlier corrections and serves as a regression diagnostic. The excerpt SHA-256 is `8f4b966f7c1138f78589e53495b246270e1d0ea5ab2df2d53fc311bdbbbaba22`. Positive windows relative to the excerpt are 11.94–21.59, 123.00–126.24 and 147.36–163.61 s. Negative windows are 21.60–53.87, 60.60–79.01, 103.86–116.39, 118.60–120.95, 126.25–137.81 and 163.62–176.90 s.

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
