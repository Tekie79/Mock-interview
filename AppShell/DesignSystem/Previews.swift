#if DEBUG || M12_UI_FIXTURES
import AppKit
import ConversationCore
import SwiftUI

enum WorkspaceFixture {
    static var isEnabled: Bool {
        #if M12_UI_FIXTURES
        true
        #else
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #endif
    }

    static let profile = InterviewProfile(name: "Jordan Ellis", role: "Platform Engineer",
                                          seniority: "Senior", industry: "Developer infrastructure")

    #if M12_UI_FIXTURES
    @MainActor static func captureWindow() {
        guard let view = NSApp.keyWindow?.contentView, !view.bounds.isEmpty else { return }
        let bounds = view.bounds
        guard let image = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { return }
        let directory = URL(fileURLWithPath: "/tmp/mock-interview-ui-captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = NSApp.keyWindow?.title.replacingOccurrences(of: " ", with: "-") ?? "Workspace"
        try? png.write(to: directory.appendingPathComponent("\(Date.now.timeIntervalSince1970)-\(name).png"), options: .atomic)
    }
    #endif
}

actor FixtureAudio: AudioSource {
    private var output: AsyncThrowingStream<AudioFrame, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<AudioFrame, Error> {
        let (stream, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.output = output
        return stream
    }
    func stop() async { output?.finish(); output = nil }
}

actor FixtureRecognition: StreamingSTT {
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var source: CaptureSource?
    private var epoch: UUID?
    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        self.source = source
        self.epoch = epoch
        return stream
    }

    func append(_ frame: AudioFrame) async throws {}
    func commit() async throws {}
    func close() async { output?.finish() }

    func send(_ text: String, id: String) {
        guard let source, let epoch else { return }
        var timing = PipelineTiming()
        timing.speechStart = .now.advanced(by: .milliseconds(-600))
        timing.endpoint = .now
        timing.audioTimingBasis = .localSpeechEstimate
        output?.yield(.init(source: source, epoch: epoch, itemID: id, text: text, state: .final, timing: timing))
    }
}

struct FixtureClassifier: QuestionClassifier {
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        guard input.turn.text.contains("?") else { return .init(decision: .ignore) }
        return .init(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text])
    }
}

struct FixtureAnswer: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                for paragraph in [
                    "**Start with the guarantee**\n\nI would write down which messages need ordering and where the guarantee ends.\n\n",
                    "**Separate delivery from processing**\n\nI would attach a sequence number, make handlers idempotent, and decide when the checkpoint advances. The database records the checkpoint with the result.\n\n",
                    "**Validate under failure**\n\nI would replay a timeout, a worker restart, and a duplicate message. The check is whether the emitted result still matches the committed order."
                ] {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                    output.yield(.text(paragraph))
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}

#if DEBUG
struct WorkspaceLayoutPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            WorkspaceNavigation(model: WorkspaceModel()).frame(width: 1120, height: 720)
                .previewDisplayName("Workspace · Live")
            CompactView(model: WorkspaceModel()).frame(width: 300, height: 240)
                .preferredColorScheme(.dark).previewDisplayName("Compact · Dark")
            ProviderSettingsView(model: WorkspaceModel()).frame(width: 780, height: 580)
                .preferredColorScheme(.light).previewDisplayName("Settings · Light")
            SoloPracticeView(model: WorkspaceModel()).frame(width: 620, height: 500)
                .previewDisplayName("Practice")
            if let store = try? KnowledgeStore() {
                ProfileEditor(model: WorkspaceModel(), store: store, embedded: true)
                    .frame(width: 820, height: 600).previewDisplayName("Profiles")
                InterviewReviewView(model: WorkspaceModel(), store: store, current: nil, embedded: true)
                    .frame(width: 850, height: 600).previewDisplayName("History")
            }
            ContextInspector(model: WorkspaceModel(), useAsQuestion: { _ in })
                .frame(width: 290, height: 540).previewDisplayName("Inspector")
        }
    }
}
#endif
#endif
