# Active execution plan — initial cloud implementation

Scope: implement M00–M07 P0 in sequence, then M08–M10 P1 in subsequent checkpoints/tasks (or current task if capacity and scope permit); defer final hardware acceptance to M11. Start with M00–M04 end-to-end vertical slice. This file is a planning template and must be revised by the implementation agent.

- Inspect repository and run baseline commands; record platform, toolchain, access and limitations.
- Checkpoint 1 (M00): native project and modular Swift packages, dependency injection, deterministic pipeline harness; document SDK/provider spikes separately.
- Checkpoint 2 (M01–M02): source contracts, replay, bounded processing, actual Apple adapters and actual OpenAI streaming adapter, fixtures; platform-dependent validation pending if unavailable.
- Checkpoint 3 (M03–M04): turn assembly, role and question gate, structured classifier, real text streaming, cancellation; demonstrate with replay and fake providers.
- Checkpoint 4 (M05–M07): facts, storage, SwiftUI, settings, error recovery and packaging instructions; no fake required controls.
- Record test commands/results, separate qualified/unqualified features, relevant changes and next step after every checkpoint. Do not mark a milestone fully qualified without its exit evidence. Use a PR or reviewable diff; no automatic merge.

Open risks: no actual macOS SDK in Linux cloud, no provider keys by default, changing provider APIs, cloud toolchain availability, mixed microphone ambiguity, response latency. Keep real device/provider validation queued, not fabricated.
