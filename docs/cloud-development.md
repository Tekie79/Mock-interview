# Codex Cloud development

## Working repository

The owner-selected working repository is https://github.com/Tekie79/Mock-interview (default branch `main`). Use this existing repository; do not create another repository or overwrite its history. It was public when the bootstrap was prepared. Keep credentials, personal résumés, transcripts, recordings, and local profiles out of source control. No distribution license has been selected.

Connect this repository to Codex Cloud at https://chatgpt.com/codex. Create and publish an environment, select `main` as the starting branch, and submit the assignment in `prompts/CODEX_CLOUD_IMPLEMENTATION.md`. The owner must start the task if a task-creation integration is not available. No task is assumed to be submitted by publishing this document.

Official product instructions: https://help.openai.com/en/articles/20001545-using-codex-cloud and https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex.

## Environment

Use a Linux environment with Git, Bash and a supported Swift 6.x toolchain installed before the task starts (e.g. a compatible environment image or official Swift installation from https://www.swift.org/install/). `scripts/cloud-setup.sh` validates prerequisites and runs an offline smoke test; it intentionally does not download/install a toolchain. Set the environment setup command to `./scripts/cloud-setup.sh` if appropriate. No dependencies or paid service credentials are required for the bootstrap. Add a verified dependency installation step only when required by implementation. If Swift cannot be provisioned, explicitly record the blocker; do not report tests as passing.

Prefer no live API secrets in the environment and run deterministic fixtures first. Never place API keys in source files, prompts, logs or CI YAML. A separate authorized Mac smoke test can use runtime Keychain or an opt-in environment credential. Internet access may be needed for official docs or pinned dependencies; limit access to the necessary services according to workspace policy.

## Native macOS verification

Cloud Linux can build/test portable Swift code and prepare Mac-specific source/project configuration. macOS SDK compilation, signing, TCC permissions, real application audio capture, device routes and UI automation must be verified on a Mac (some compilation/testing via a macOS GitHub Actions runner). The baseline macOS CI workflow tests only the initial SPM package; extend it when the Xcode app exists. A CI run is not assumed to have occurred. No Apple-only runtime claims from Linux.

## Review workflow

Keep implementation on an isolated branch, with milestone commits, updated status/plan, actual tests, and open blockers. Review the task diff/PR before merge. If splitting the work, continue the same task or commit/push its changes before starting another isolated task. Never force push, auto-merge or release. After implementation, run M11 qualification on Apple Silicon hardware with the real providers and the full acceptance matrix.

## M10.1 development

Check out the M10.1 feature branch against the reviewed V1 base. Run `./scripts/build.sh`, `./scripts/test.sh` and `git diff --check` per checkpoint. Debian needs the SQLite and zlib headers and Swift 6.x. Hosted macOS CI runs the portable suite and `./scripts/package-macos.sh`; Darwin-only noninteractive tests are picked up by SwiftPM there. SpeechAnalyzer is compiled when the toolchain includes the macOS 26 Speech APIs. Apple Speech permissions, real Core Audio routes and live credentials are outside the default cloud job. See [M10.1 verification](verification/m10-1.md).
