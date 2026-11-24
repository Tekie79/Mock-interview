# Provider and platform qualification

Source of truth: requirements §5–6, §9 and §15. Provider payloads and model availability can change. All live integration status starts unverified.

| Role | Baseline | Adapter policy |
|---|---|---|
| STT P0 | OpenAI Realtime transcription (`gpt-live-transcribe` proposed) | Verify current model, endpoint, auth, session update, audio format, delta/completed events and explicit commit requirements. Per-source streams. |
| LLM P0 | OpenAI Responses API | Streaming text, structured question decisions, configured model IDs, validate schema, handle errors and cancellation. |
| STT P1 | Deepgram | Verify chosen model and endpointing, normalize into domain events. |
| LLM P1 | Anthropic Claude | Stream text; structured decision capability must be tested, no silent fallback to unsupported model. |
| Audio | Core Audio taps / AVAudioEngine / optional ScreenCaptureKit | Verify minimum OS, permission strings, route/termination, fallback scope and cleanup with Apple SDK. |

No live credentials in CI; fixtures represent protocol events and must be labeled synthetic or sanitized. Tests must cover unknown/additional fields, malformed data, provider item ordering, cancellation, timeout, authentication, rate limits and stream disconnect. Do not claim model availability until verified; document observed errors and adapter contract revisions in decisions.

References (also in requirements §15):
- https://developers.openai.com/api/docs/guides/realtime-transcription
- https://developers.openai.com/api/docs/guides/streaming-responses
- https://developers.openai.com/api/docs/guides/structured-outputs
- https://developers.deepgram.com/docs/understand-endpointing-interim-results
- https://docs.anthropic.com/
- https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
