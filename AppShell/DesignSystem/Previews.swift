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
        if request.question.hasPrefix("Load fixture") {
            return AsyncThrowingStream { output in
                for _ in 0..<8 { output.yield(.text("Synthetic replay notes show how to verify checkpoint order. ")) }
                output.finish()
            }
        }
        return AsyncThrowingStream { output in
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
            ForEach(InterviewPresentation.allCases) { mode in
                FixturePreview { model in
                    InterviewAnswerView(model: model, fontSize: 16, previewPresentation: mode)
                }.frame(width: 760, height: 560).previewDisplayName(mode.rawValue)
                FixturePreview { model in CompactView(model: model, previewPresentation: mode) }
                    .frame(width: 300, height: 240).preferredColorScheme(.dark)
                    .previewDisplayName("Compact · " + mode.rawValue)
            }
            ForEach(ProviderSettingsView.Category.allCases) { category in
                ProviderSettingsView(model: WorkspaceModel(), initialCategory: category)
                    .frame(width: 780, height: 580).preferredColorScheme(.light)
                    .previewDisplayName("Settings · " + category.rawValue)
            }
            SoloPracticeView(model: WorkspaceModel()).frame(width: 620, height: 500)
                .previewDisplayName("Practice")
            FixturePreview { model in
                if let store = model.store { ProfileEditor(model: model, store: store, embedded: true) }
            }.frame(width: 820, height: 600).previewDisplayName("Profiles")
            FixturePreview { model in
                if let store = model.store { InterviewReviewView(model: model, store: store, current: nil, embedded: true) }
            }.frame(width: 850, height: 600).previewDisplayName("History and review")
            ForEach(ContextInspector.Tab.allCases, id: \.self) { tab in
                FixturePreview { model in ContextInspector(model: model, useAsQuestion: { _ in }, initialTab: tab) }
                    .frame(width: 290, height: 540).previewDisplayName(tab.rawValue)
            }
        }
    }
}

private struct FixturePreview<Content: View>: View {
    @State private var model = WorkspaceModel()
    @ViewBuilder let content: (WorkspaceModel) -> Content

    var body: some View {
        content(model)
            .padding(Studio.tight)
            .background(Studio.canvas)
            .tint(Studio.accent)
            .task { if model.store == nil { await model.load() } }
    }
}
#endif
#endif
