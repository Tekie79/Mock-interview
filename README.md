# Live AI Mock Interview Assistant

A native macOS app for mock interviews and solo practice. It listens to selected audio, transcribes each source separately, and streams text suggestions for complete interviewer questions while capture continues.

## Run on a Mac

Requires Apple Silicon, macOS 14.2 or later, and Xcode with a macOS SDK that supports Core Audio process taps.

1. Open `MockInterview.xcodeproj`, select the **MockInterview** scheme, and run. For a local unsigned release build, run `./scripts/package-macos.sh`.
2. Open **Settings** and choose **Apply OpenAI M11 Configuration** for the models under production qualification. Transcription, classification, answers and optional embeddings can also be selected independently. API keys are stored in Keychain. Connection tests use synthetic inputs and can incur provider charges. ChatGPT subscription sign-in is unavailable pending eligibility.
3. Choose question audio from the macOS default output, a supported specific digital device, an application/process group, a microphone, or replay. Optionally enable a separate candidate microphone. **Test Audio** shows levels locally. Allow the indicated macOS permissions.
4. In **Profiles**, name your profile and use **Attach as** to choose Résumé, Job description, or Project notes. **Attach Files…** supports Markdown (`.md`, `.markdown`), text, PDF, and DOCX. Under **Answer training**, add skills, a sample answer in your own words, and real project stories. Use **Edit** on any fact to correct or exclude it. Select that profile before starting the session.
5. In **Settings → Answer generation**, choose an answer format and enter a **Requested word limit** from 1 to 400. The model can exceed the request. Use **0** for the format default. The answer card’s **Format** menu regenerates the selected answer in another style.
6. Start the interview. Choose **Focus** for one answer or **Chat** for chronological answers in the workspace or compact window. Scroll up in Chat to pause following and select **Jump to Latest** to resume. Temporary dialogue context is used during the session. In Settings, optionally enable older-dialogue summaries with OpenAI. Save an individual transcript and answer history from **Review and History**.

For OpenAI, use an independently captured interviewer feed and select a separate candidate microphone. If the call plays out loud on a second device and only one Mac microphone is available, **Interview on another device** can capture the room for manual answers. The optional ElevenLabs Scribe v3 Live and Deepgram Nova speaker-label configurations are outside M11 production qualification.

System, application and replay audio starts in **Mixed audio · Manual answers**. Choose **Mixed audio · Assign speakers** with a transcription model that supplies speaker labels, then assign the interviewer in **Transcript**. Use **Interviewer-only audio** only for a source dedicated to the interviewer. Enabling the independent candidate microphone does not establish the role of the question source. Facts still marked pending in older profiles are excluded until you enable them in the profile editor.

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
