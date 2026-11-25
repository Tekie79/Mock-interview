# Live AI Mock Interview Assistant

A native macOS app for mock interviews and solo practice. It listens to selected audio, transcribes each source separately, and streams text suggestions for complete interviewer questions while capture continues.

## Run on a Mac

Requires Apple Silicon, macOS 14.2 or later, and Xcode with a macOS SDK that supports Core Audio process taps.

1. Open `MockInterview.xcodeproj`, select the **MockInterview** scheme, and run. For a local unsigned release build, run `./scripts/package-macos.sh`.
2. Open **Settings**. Choose transcription, classification, answers and optional embeddings independently, or apply a preset. API keys are stored in Keychain. Each service has its own connection test. Tests can incur provider charges. Apple Speech offers strict on-device processing where installed. ChatGPT subscription sign-in is unavailable pending eligibility.
3. Choose question audio from the macOS default output, a supported specific digital device, an application/process group, a microphone, or replay. Optionally enable a separate candidate microphone. **Test Audio** shows levels locally. Allow the indicated macOS permissions.
4. In **Profiles**, add your résumé, job description, and project notes from text, Markdown, PDF, or DOCX. Confirm the experience facts the assistant may use. Select that profile before starting the session.
5. In **Settings → Answer generation**, choose an answer format and enter an optional word limit from 1 to 400. Use **0** for the format default. The answer card’s **Format** menu regenerates the selected answer in another style.
6. Start the interview. Use the native workspace or compact window to review suggestions and control the session. Transcript and answers are kept in memory by default. Select local retention or save an individual session from **Review and History**.

For an interview running on a second device, turn on **Interview on another device**, choose the Mac’s **Room microphone**, and play the call through the other device’s speakers. Select ElevenLabs Scribe v3 Live or a supported Deepgram Nova model for transcription. After **Start**, match the detected speakers in **Transcript** and assign **Interviewer** and **Candidate**. Confirm labels again after a reconnect or speaker merge.

In **Settings → Question classification**, adjust **Wait for silence** to hold short pauses open. It starts at two seconds and can be changed during a session. Finalized pieces from the same speaker within the quiet window are answered together. Choose **0** for immediate handling of finalized questions.

The app accepts raw mono signed PCM16 little-endian replay at 24 kHz. Live replay uses the selected transcription provider. The deterministic developer replay test uses synthetic audio and test transports.

## Develop

- Install Swift 6.x on Linux or use the Xcode toolchain on macOS. On Debian or Ubuntu, install `libsqlite3-dev`, `zlib1g-dev`, and `pkg-config`. The macOS SDK supplies SQLite and zlib.
- Run `./scripts/build.sh` and `./scripts/test.sh`. Deterministic tests require no provider credentials or network.
- Read the [requirements](docs/requirements.md), [development plan](PLANS.md), [implementation status](docs/implementation-status.md), and [acceptance plan](docs/acceptance-test-plan.md) for scope and the distinction between development and final qualification.

The GitHub Actions workflow builds the portable package, runs deterministic tests, and compiles the native app on a hosted Mac. The implementation status records real-provider and physical-device checks separately.

## Repository policy

Use feature branches and reviewed changes. Do not merge or publish releases automatically. No distribution license has been selected.

## Qualification evidence

See [requirements traceability](docs/requirements-traceability.md), [audio compatibility](docs/audio-routing.md), [provider capabilities](docs/provider-compatibility.md), and [pipeline and timing](docs/realtime-pipeline.md). See [M11 acceptance](docs/verification/m11-final-acceptance.md) for native and live provider observations and [release readiness](docs/release-readiness.md) for outstanding qualification gates. Hosted packaging checks build an unsigned bundle.
