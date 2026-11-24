# Live AI Mock Interview Assistant

A macOS-first native application for live mock interviews and training. Listen to a selected remote mock interviewer or microphone, recognize complete relevant questions, and stream grounded text suggestions while continuing to listen. This is the initial development repository, not a working desktop application.

## Development baseline

- Apple Silicon, macOS 14.2+; SwiftUI/AppKit for the app; Swift Package Manager for portable core modules.
- Swift 6.x toolchain recommended. Package currently uses Swift 5.9 manifest/language compatibility to permit the initial core to run on multiple Swift toolchains.
- Local-first profiles, BYOK cloud STT/LLM; no mandatory app-level consent workflow; operating system permissions remain mandatory.
- No real personal records, recordings, API keys, or provider traffic in source control or deterministic tests.

## Start here

1. Read [AGENTS.md](AGENTS.md), [requirements](docs/requirements.md), [architecture](docs/architecture.md), [PLANS.md](PLANS.md), and [acceptance plan](docs/acceptance-test-plan.md).
2. Run `./scripts/test.sh` (requires Swift). The initial package contains only a small role-policy contract and smoke tests.
3. Run `./scripts/build.sh` for the portable package. On a Mac the future desktop app must also build with Xcode; its project does not exist yet.
4. Read [cloud setup and handoff](docs/cloud-development.md) and submit [the cloud implementation prompt](prompts/CODEX_CLOUD_IMPLEMENTATION.md) to a Codex Cloud task.
5. Track milestone progress and actual verification in [implementation status](docs/implementation-status.md).

The authoritative requirements are `docs/requirements.md`. The derived documents clarify engineering and test execution without replacing those requirements. See [provider compatibility](docs/provider-compatibility.md) for the live API verification policy and [fixture schema](Tests/Fixtures/README.md) for synthetic test cases.

## Repository policy

Use feature branches and reviewed pull requests. Do not merge or publish releases automatically. No license chosen; ask the owner before distribution or adding a license. Working title and repository name are provisional.
