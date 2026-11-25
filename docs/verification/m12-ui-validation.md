# M12 native UI validation

**Decision: native UI review candidate. Production distribution is on hold.**

Base `a843a565ef0c9f7ed5d4c9a3bb3bd9bb5a318d0a` passed 148 Linux, 158 macOS 15 and 159 macOS 26 tests and both unsigned macOS builds. The M12 PR checks identify the audited M12 commit and per-platform logs. Use the exact head listed in PR verification when reproducing the local artifact.

## Screenshots

These sanitized AppKit captures used synthetic profiles and deterministic providers. The M11 comparison ran the reviewed M11 source with the fixture injected only for capture. The M12 fixture build excludes customer databases, Keychain lookups and physical audio.

| Surface | Capture |
| --- | --- |
| Before and after | [M11 before](../design/screenshots/m11-before-focus.png) · [M12 Focus](../design/screenshots/m12-focus.png) |
| Chat and inspectors | [Chat](../design/screenshots/m12-chat.png) · [Transcript](../design/screenshots/m12-transcript.png) · [Learned Context](../design/screenshots/m12-context.png) |
| Compact | [Focus](../design/screenshots/m12-compact-focus.png) · [Chat](../design/screenshots/m12-compact-chat.png) |
| Library and configuration | [Profiles](../design/screenshots/m12-profiles.png) · [Practice](../design/screenshots/m12-practice.png) · [General](../design/screenshots/m12-settings-general.png) |

## Feature and evidence matrix

| Feature | Implementation and evidence |
| --- | --- |
| Live and navigation | Session controls stay visible across sidebar destinations. Native synthetic session continued listening while visiting Profiles, History and Practice. The unsigned production application opened on macOS 26.3.2. |
| Focus and Chat | Shared format-aware rendering, copy, retry, regenerate, cancel and evidence. Native Chat observation confirmed scroll suspension, new-answer count and Jump to Latest. Geometry tests exercise useful content inside, outside and clipped by the viewport and a hidden window. |
| Compact | Native fixture displayed the same session in both modes and expanded to the existing workspace. Frame and top preference use native window settings. |
| Transcript and learned context | Native fixture showed attributed interviewer and candidate speech, plus correction, exclusion and provenance controls. Temporal and invalidation tests exercise late prior candidate speech, exclusion of future turns, corrections, summary revocation and no-save shutdown. |
| Profiles | Profile sections, imports, editable project stories and evidence status. Deterministic duplication test preserves exclusions and document ownership. |
| History, Review and Practice | Native list/detail workspace, search and saved-session filtering. Review labels actual speech, AI suggestion and coaching separately. |
| Settings | General, Audio, AI and Models, Answer Preferences, Interview Context, Privacy and Storage, Diagnostics. Existing Keychain, provider and routing boundaries apply. |
| Packaging | Build with `./scripts/package-macos.sh`. Bundle validation checks universal arm64/x86_64, minimum macOS 14.2, version 1.0.0 (12.0), permission descriptions and unsigned output. |

## Processing comparison

M11 acknowledged answer publication or scrolling as a UI proxy. M12 requires a sufficiently visible portion of the first substantive answer block in an onscreen AppKit scroll viewport. The probe uses an eight-character text heuristic and cannot establish that a response is useful to a human observer. M12 publishes initial text immediately, coalesces later stream updates at roughly 42 ms and limits programmatic Chat scrolling to approximately once per 100 ms. This is a change in instrumentation and publication cadence. A registered independent speech-end-to-display latency comparison and sustained loaded-window rendering benchmark are still due.

## Remaining release gates

- OpenAI qualification on the redesigned artifact, including independent speaker-attributed holdout precision and recall, independently observed useful-visible latency and curated live grounding.
- Physical interviewer and candidate capture, at least 20 supported dual-source start/stop cycles, and source switching and interruption evidence.
- Sustained Chat rendering with two windows and a real 90-minute remote session. A second controlled meeting endpoint remains unavailable.
- Supported clean installation and upgrade on both macOS tracks. Unsigned bundle loading is development evidence.
- Full assistive-technology and keyboard certification, extended screen and streaming regressions, and remaining UI screenshot coverage as recorded in the PR.

Optional provider live qualification was deferred. The ChatGPT subscription integration stays gated. No production release was signed, notarized or published.
