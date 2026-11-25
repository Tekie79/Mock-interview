# M10.1 development execution

Base is `feature/v1-cloud-implementation` at `ea24dc780aeca50358ba452446f3c5b99a3ecaba`. Work on `feature/m10-1-pipeline-hardening` and leave M11 for a separate qualification run.

| Checkpoint | Scope and development evidence |
|---|---|
| A | Bounded ordered ingestion/classification and session/source failure regression |
| B | Role-labelled context, stage timings, provider drain and cancellation fixtures |
| C | Digital output taps, stable route identifiers, independent candidate input and epoch-safe switching |
| D | Provider capability and common audio contracts, truthful availability gates |
| E | Apple Speech adapter and strict/local mode policy |
| F | ElevenLabs WebSocket adapter and official-wire fixtures |
| G | OpenAI and Deepgram drain, timestamps, error and model-contract corrections |
| H | Official ChatGPT subscription eligibility, independent authorization boundary and fail-closed tests |
| I | Independent settings, credentials, and persisted presets |
| J | Trace FR-01–21 and M10.1, fix verified regressions, run development checks and open PR |

Use the portable build and test scripts at each checkpoint. Hosted macOS CI owns Xcode compilation and the unsigned package check. Report runtime, provider-account and physical-device gaps separately. Confirm external authorization eligibility before enabling subscription features.

## Review handoff

The A–J code commits and linked traceability table are the development review baseline. Follow the documented live eligibility gate for ChatGPT. Review unresolved coverage, then plan a separate M11 run on supported Apple Silicon hardware with representative devices, synthetic recordings and approved provider test accounts.
