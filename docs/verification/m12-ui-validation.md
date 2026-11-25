# M12 native UI validation

**Decision: native UI review candidate. Production distribution is on hold.**

Base `a843a565ef0c9f7ed5d4c9a3bb3bd9bb5a318d0a` passed 148 Linux, 158 macOS 15 and 159 macOS 26 tests and both unsigned macOS builds. The [M12 pull request verification](https://github.com/Tekie79/Mock-interview/pull/4) records the audited commit, per-platform run logs and unsigned archive checksum.

## Screenshots

These sanitized screenshots show the running native windows using synthetic profiles and deterministic providers. The M11 comparison ran the reviewed M11 source with the fixture injected only for capture. The M12 fixture build excludes customer databases, Keychain lookups and physical audio.

| Surface | Capture |
| --- | --- |
| Before and after | [M11 before](../design/screenshots/m11-before-focus.jpg) · [M12 Focus](../design/screenshots/m12-focus.jpg) |
| Chat and inspectors | [Chat](../design/screenshots/m12-chat.jpg) · [Transcript](../design/screenshots/m12-transcript.jpg) · [Learned Context](../design/screenshots/m12-context.jpg) |
| Compact | [Focus](../design/screenshots/m12-compact-focus.jpg) · [Chat](../design/screenshots/m12-compact-chat.jpg) |
| Library and configuration | [Profiles and editor](../design/screenshots/m12-profiles.jpg) · [Documents](../design/screenshots/m12-profile-documents.jpg) · [History](../design/screenshots/m12-history.jpg) · [Review](../design/screenshots/m12-review.jpg) · [Practice](../design/screenshots/m12-practice.jpg) |
| General appearances | [Light](../design/screenshots/m12-settings-light.jpg) · [Dark](../design/screenshots/m12-settings-dark.jpg) |
| Settings categories | [Audio](../design/screenshots/m12-settings-audio.jpg) · [AI and Models](../design/screenshots/m12-settings-ai.jpg) · [Answer Preferences](../design/screenshots/m12-settings-answers.jpg) · [Interview Context](../design/screenshots/m12-settings-context.jpg) · [Privacy and Storage](../design/screenshots/m12-settings-privacy.jpg) · [Diagnostics](../design/screenshots/m12-settings-diagnostics.jpg) |
| Chat load | [Workspace](../design/screenshots/m12-main-long-list.jpg) · [Compact](../design/screenshots/m12-compact-long-list.jpg) |

## Feature and evidence matrix

| Feature | Implementation and evidence |
| --- | --- |
| Live and navigation | Session controls stay visible across sidebar destinations. Native synthetic session continued listening while visiting Profiles, History and Practice. The unsigned production application opened on macOS 26.3.2. |
| Focus and Chat | Shared format-aware rendering, copy, retry, regenerate, cancel and evidence. Native Chat observation confirmed scroll suspension, new-answer count and Jump to Latest. Geometry tests exercise useful content inside, outside and clipped by the viewport and a hidden window. Tested answer visibility on the running fixture using matching synthetic fixtures with visible and offscreen answer text. |
| Compact | Native fixture displayed the same session in both modes and expanded to the existing workspace. Both modes were also inspected at 300 pt width. Frame and Always on Top use native window settings. |
| Transcript and learned context | Native fixture showed attributed interviewer and candidate speech, plus correction, exclusion and provenance controls. Excluding a candidate item withdrew the dependent answer, and explicit regeneration reused the logical question with a manual origin. Temporal and invalidation tests exercise late prior candidate speech, exclusion of future turns, corrections, summary revocation and no-save shutdown. |
| Profiles | Profile sections, imports, editable project stories and evidence status. Deterministic duplication test preserves exclusions and document ownership. |
| History, Review and Practice | Native list/detail workspace, search and saved-session filtering. Review labels actual speech, AI suggestion and coaching separately. |
| Settings | General, Audio, AI and Models, Answer Preferences, Interview Context, Privacy and Storage, Diagnostics. All seven categories were opened in the native fixture. System, Light and Dark were selected or observed. The app retained its appearance and view settings across launch. Existing Keychain, provider and routing boundaries apply. |
| Packaging | Build with `./scripts/package-macos.sh`. Bundle validation checks universal arm64/x86_64, minimum macOS 14.2, version 1.0.0 (12.0), permission descriptions and unsigned output. |

## Processing comparison

M11 used answer publication or scrolling as a visibility proxy. M12 checks the first substantive answer block against AppKit viewport clipping and window visibility. The probe uses an eight-character heuristic and requires 75% of the probe region to be visible. In the timestamped native synthetic example, diagnostics recorded **651 ms** to visible text and **1,134 ms** to terminal. Diagnostics omitted the visibility metric for the latest answer completed offscreen. These synthetic examples establish instrumentation behavior. Independent speech-end-to-useful-display latency remains open.

Initial text publishes immediately. Intermediate text snapshots are coalesced at approximately 42 ms. Chat follows with at most one queued scroll per 100 ms. Meter, transcripts and answer history have independent observation boundaries. The initial 200-answer burst with both windows open stalled on SwiftUI layout, reaching approximately 1.3 GiB of process RSS before the synthetic process was stopped. The native-list retest reached all 200 injected answers and continued listening. Both windows reached the same latest entry, and manual scrolling and Jump to Latest worked. This is a bounded synthetic stress result. A sustained production session and resource profile remain due.

The burst is reproducible by building with the synthetic fixture configuration and opening Focus or Chat. From Chat, open Compact and choose **Verification → Load 200 Chat Entries** after the initial automatic answers complete. Use **Settings → Diagnostics** for answer counts. The fixture uses independent local stub transports and makes zero provider calls.

## Remaining release gates

- OpenAI qualification on the redesigned artifact, including independent speaker-attributed holdout precision and recall, independently observed useful-visible latency and curated live grounding.
- Physical interviewer and candidate capture, at least 20 supported dual-source start/stop cycles, and source switching and interruption evidence.
- Sustained Chat rendering with two windows and a real 90-minute remote session. A second controlled meeting endpoint remains unavailable.
- Supported clean installation and upgrade on both macOS tracks. Unsigned bundle loading is development evidence.
- Full assistive-technology and keyboard certification, timed rendering under sustained streams, and coverage on each supported physical macOS version.

The initial M12 redesign verification used no paid provider calls. The system-output follow-up below includes a short live OpenAI run. Optional provider live qualification was deferred. The ChatGPT subscription integration stays gated. No production release was signed, notarized or published.

### System output follow-up

On 2026-11-25, the original build captured seven seconds and finalized four segments from MacBook Pro Speakers. Mixed audio mode marked all four segments ineligible for automatic answers. Local Test Audio subsequently measured normalized RMS of approximately 0.0087 with controlled playback on that hardware. macOS requested system audio permission again for the unsigned bundle and frames arrived after authorization.

The owner identified the live Zoom output as interviewer-only. After saving that attribution for MacBook Pro Speakers, the standard app submitted 16 seconds of PCM, finalized six transcript segments and completed two automatic answers using `gpt-live-transcribe`, GPT-6 Luna with no reasoning for classification, and GPT-6.2 Sol at low reasoning for generation. A third accepted question was still in progress at Stop. The session then reported zero connected sources. This short observation uses a live, owner-designated interviewer feed and carries no release endurance or independent latency qualification.

Build 12.1 makes the automatic and manual choice visible when starting with an unconfirmed output. It shows listening and manual-answer status together for unresolved audio, exposes the transcript path and uses capture-source identities for meters. Automatic attribution remains scoped to the selected source. A different unconfirmed output still requires speaker assignment or a deliberate interviewer-only designation.

### Answers Only

Build 12.2 adds an optional Answers Only mode from the answer toolbar and General settings. Native fixture checks confirmed question headers disappear in Focus and Chat, answer content and Copy and Regenerate stay available, Compact and the workspace share the preference, and relaunch retains it.
