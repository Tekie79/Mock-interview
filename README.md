# Live AI Mock Interview Assistant

A native macOS app for mock interviews and solo practice. It listens to selected audio, transcribes each source separately, and streams text suggestions for complete interviewer questions while capture continues.

## Run on a Mac

Requires Apple Silicon, macOS 14.2 or later, and Xcode with a macOS SDK that supports Core Audio process taps.

1. Open `MockInterview.xcodeproj`, select the **MockInterview** scheme, and run. For a local unsigned release build, run `./scripts/package-macos.sh`.
2. Open **Settings**. Choose transcription, classification, answers and optional embeddings independently, or apply a preset. API keys are stored in Keychain. Each service has its own connection test. Tests can incur provider charges. Apple Speech offers strict on-device processing where installed. ChatGPT subscription sign-in is unavailable pending eligibility.
3. Choose question audio from the macOS default output, a supported specific digital device, an application/process group, a microphone, or replay. Optionally enable a separate candidate microphone. **Test Audio** shows levels locally. Allow the indicated macOS permissions.
4. Optionally create a profile, import text, Markdown, PDF, or DOCX, and confirm the experience facts the assistant can use.
5. Start the interview. Use the native workspace or compact window to review suggestions and control the session. Transcript and answers are kept in memory by default. Select local retention or save an individual session from **Review and History**.

The app accepts raw mono signed PCM16 little-endian replay at 24 kHz. Live replay uses the selected transcription provider. The deterministic developer replay test uses synthetic audio and test transports.

## Develop

- Install Swift 6.x on Linux or use the Xcode toolchain on macOS. On Debian or Ubuntu, install `libsqlite3-dev`, `zlib1g-dev`, and `pkg-config`. The macOS SDK supplies SQLite and zlib.
- Run `./scripts/build.sh` and `./scripts/test.sh`. Deterministic tests require no provider credentials or network.
- Read the [requirements](docs/requirements.md), [development plan](PLANS.md), [implementation status](docs/implementation-status.md), and [acceptance plan](docs/acceptance-test-plan.md) for scope and the distinction between development and final qualification.

The GitHub Actions workflow builds the portable package, runs deterministic tests, and compiles the native app on a hosted Mac. The implementation status records real-provider and physical-device checks separately.

## Repository policy

Use feature branches and reviewed changes. Do not merge or publish releases automatically. No distribution license has been selected.

## M10.1 development evidence

See [requirements traceability](docs/requirements-traceability.md), [audio compatibility](docs/audio-routing.md), [provider capabilities](docs/provider-compatibility.md), and [pipeline and timing](docs/realtime-pipeline.md). The hosted release build is an unsigned packaging check. Physical Mac and live provider qualification are handled in M11.
