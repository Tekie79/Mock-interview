# V1 cloud implementation

Work on `feature/v1-cloud-implementation` in M00–M10 dependency order. M11 owns final acceptance.

| Checkpoint | Code and evidence |
| --- | --- |
| M00 | Native app target, portable contracts, deterministic fixture harness, CI app compilation |
| M01 | Replay and selected-source capture, audio normalization, metering, VAD and lifecycle tests |
| M02 | OpenAI transcription transport, ordering, reconnect and protocol fixtures |
| M03 | Final-turn gating, classification, context, deduplication and labeled tests |
| M04 | OpenAI answer streaming, grounding, cancellation and deterministic integration tests |
| M05 | Profile imports and approved facts, SQLite search and grounding tests |
| M06 | Native workspace, compact window, settings, Keychain and accessibility |
| M07 | Recovery, diagnostics, retention and packaging |
| M08 | Deepgram and Anthropic protocols and independent configuration |
| M09 | Session review, export, rubric and solo practice |
| M10 | DOCX, optional embeddings and user-assigned diarized speaker roles |

Run `./scripts/build.sh` and `./scripts/test.sh` throughout. Track native compilation, real device behavior and provider live checks separately in the implementation status and verification evidence. Cloud Linux lacks Xcode and audio devices, and no provider credentials are configured.

## Development handoff

The feature branch contains the M00–M10 checkpoints in dependency order. See the implementation status for verified results and remaining hardware work. The next checkpoint is M11 final acceptance on an Apple Silicon Mac with opt-in test provider accounts. Start with a packaged app launch, source permissions and dual-channel isolation, then use the acceptance plan for held-out semantic, grounding, mixed microphone and latency/stability measurements.
