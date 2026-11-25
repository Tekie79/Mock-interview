# M11 audio compatibility

Host is the Apple M5 Pro MacBook Pro (Mac17,8), macOS 26.3.2 build 25D2150. The baseline native bundle used the approved M10.2 source `6fdcc4b3e35c489499e4f1014cd69f5ce98167ed` with the local Swift 6.3.2 compiler and SDK 26.5. No audio recordings from the capture device were persisted. Locally generated speech supplied the stimulus.

| Route or behavior | Status | Evidence and scope |
|---|---|---|
| Default output capture | Passed | On the local native baseline, Test Audio showed a Question RMS meter reading of 0.02298 while the synthetic source played through the default built-in speakers. |
| Explicit built-in speakers | Passed | Selected MacBook Pro Speakers, then observed Question RMS 0.01029 during Test Audio with synthetic playback. An immediate first attempt surfaced source unavailable and is tracked separately. |
| Output capture continuity | Passed | Synthetic player remained active during both meter observations. No listening test of audible dropouts was performed. |
| Audio test start and end | Passed | Start was disabled during Test Audio. The workspace returned to idle after the bounded test. This checks the local test-audio lifecycle. |
| Application/process selection | Passed | The native app selected the Zoom process group. Test Audio showed Question RMS 0.03743. On Start, the OpenAI connection reached Listening and the app showed multiple finals and an automatic answer. |
| Built-in microphone and candidate channel | Not tested | Built-in microphone and a Continuity input were enumerated. Independent levels and roles require a separate run. |
| Recorded PCM replay | Passed | Native file picker loaded synthetic 24 kHz PCM. OpenAI stream produced one final and an automatic answer. Manual generation, navigation, pinning, cancellation and pause/resume were exercised separately. |
| Bluetooth, USB, Thunderbolt and virtual audio | Blocked | No separate output of those types was present in the device inventory. |
| Zoom | Passed | Process-scoped capture and Stop worked. The first 33-second trial was excluded from quality and endurance when the opening stimulus did not match the qualification track. A later 120-second run ended with eight finals, five completed answers and no connected source. The owner-provided Q&A follow-up lasted 705 seconds and ended with 39 finals, 21 completed answers, zero connected sources and zero established TCP connections for the app. |
| Teams, Google Meet and browser audio | Not tested | Installed application inventory and a picker entry confer no capture compatibility claim. |
| Output change, removal, app exit, sleep and wake | Not tested | Route and teardown contracts have deterministic checks. Physical route recovery and sleep/wake need distinct real-device runs. |
| Permissions | Not tested | Baseline app obtained default and explicit output frames. The OS permission-denial sequence requires a controlled owner-led reset. |
| Isolation, leakage and overlapping speakers | Not tested | Separate deterministic roles, late-correction and overlap fixtures passed. Acoustic isolation remains unmeasured. |

The initial inventory showed built-in speakers with two channels and the built-in microphone with one channel at 48 kHz. A Continuity microphone advertised one input channel. Connection or enumeration is insufficient to claim that a device can be captured. See the [audio-routing contract](../audio-routing.md) and [defect register](m11-defect-register.md).

## M11-02 correction retest

A SwiftPM helper linked against the production Core Audio adapter on the physical Mac. With a public recorded Q&A excerpt playing locally, it started a fresh tap, measured the peak per-frame RMS, stopped it and immediately opened the next selection. Each set alternated 10 macOS default and 10 explicit MacBook Pro Speakers selections. The built-in speakers were the only output in this inventory. Each attempt used a two-second deadline.

| Adapter | Attempts above 0.001 RMS | Peak range | Route errors |
|---|---:|---|---:|
| Reviewed baseline `41c243a` | 20/20 | 0.0014418002–0.012459481 | 0 |
| Correction | 20/20 | 0.0014396926–0.011738739 | 0 |

Stream and sample-rate callbacks can report unchanged values. The correction checks actual stream IDs and rate before triggering recovery and retains device and alive-state validation. Both revisions passed the adapter exercise. The original failure remains unreproduced under this protocol, and native **Test Audio** retest is pending after the UI automation connection timed out. This setup did not exercise an actual transition between two physical outputs or microphone capture. The helper reported undetermined microphone permission. No physical cross-channel leakage, overlapping voices or acoustic cancellation measurement was made. [Apple Core Audio tap sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

## Native permission follow-up

The continuation bundle exposed system default output and an independent MacBook Pro candidate microphone in the workspace. Its combined Test Audio attempt emitted no usable meters and remained in progress past the cancellation deadline. The sample showed the Core Audio thread waiting inside `AudioDeviceCreateIOProcIDWithBlock`. The sample establishes the blocking setup call. Its cause, physical route switching, native speaker assignment and separate microphone frame delivery remain open.

The subsequent permission correction checks microphone and Speech authorization status before requesting access. Authorized states proceed directly, undetermined states use the OS request, and denied and restricted states stop the operation. Core Audio tap permissions remain controlled by macOS. Test Audio and Start still require explicit user action. [Apple capture authorization](https://developer.apple.com/documentation/AVFoundation/AVCaptureDevice/authorizationStatus%28for%3A%29)
