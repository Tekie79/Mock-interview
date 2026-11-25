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
