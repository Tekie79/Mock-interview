import Foundation
import XCTest
@testable import ConversationCore

actor HeldAudio: AudioSource {
    private var output: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    func start() -> AsyncThrowingStream<AudioFrame, Error> {
        let (stream, output) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.output = output
        return stream
    }
    func stop() { output?.finish(); output = nil }
    func fail() { output?.finish(throwing: CaptureFailure.sourceUnavailable) }
    func send(_ frame: AudioFrame) { output?.yield(frame) }
}

actor InjectedSTT: StreamingSTT {
    private var source: CaptureSource?
    private var epoch: UUID?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    func connect(source: CaptureSource, epoch: UUID) -> AsyncThrowingStream<TranscriptEvent, Error> {
        self.source = source
        self.epoch = epoch
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        return stream
    }
    func append(_ frame: AudioFrame) {}
    func commit() {}
    func close() { output?.finish(); output = nil }
    func send(_ text: String, item: String, state: TranscriptEvent.State = .final, epoch override: UUID? = nil,
              timing: PipelineTiming = .init(), usage: RecognitionUsage? = nil) {
        guard let source, let epoch else { return }
        output?.yield(.init(source: source, epoch: override ?? epoch, itemID: item, text: text, state: state,
                            timing: timing, recognitionUsage: usage))
    }
}

actor HeldClassifier: QuestionClassifier {
    private(set) var inputs: [QuestionInput] = []
    private let slow: Bool
    init(slow: Bool = true) { self.slow = slow }
    func classify(_ input: QuestionInput) async throws -> QuestionDecision {
        inputs.append(input)
        if slow { try await Task.sleep(for: .seconds(30)) }
        return .init(decision: .accept, normalizedQuestion: input.turn.text, parts: [input.turn.text], isFollowUp: true)
    }
}

struct FixedAnswer: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.yield(.text("Suggested response.")); $0.finish() }
    }
}

func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ProviderFailure.timeout
}

final class PipelineHardeningTests: XCTestCase {
    func testBlockedClassifierDoesNotBlockIngestionAndOverflowRetainsTranscript() async throws {
        let audio = HeldAudio()
        let stt = InjectedSTT()
        let classifier = HeldClassifier()
        let source = CaptureSource(id: "question", role: .interviewer)
        let session = InterviewSession(channels: [.init(source: source, audio: audio, makeSTT: { stt })],
                                       detector: .init(classifier: classifier), generator: FixedAnswer(), queueLimit: 1)
        await session.start()
        try await eventually { await session.current().state == .listening }
        await stt.send("Explain queues.", item: "first")
        try await eventually { await classifier.inputs.count == 1 }
        await stt.send("Explain locks.", item: "second")
        await stt.send("Explain locks.", item: "second")
        await stt.send("Explain scheduling.", item: "third")
        await stt.send("Ignored old epoch", item: "old", epoch: UUID())
        try await eventually { await session.current().discardedQuestions == 1 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.transcript.count, 3)
        XCTAssertTrue(snapshot.answers.isEmpty)
        await session.stop()
        let stopped = await session.current()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(stopped.answers.isEmpty)
    }

    func testCandidateOnlyIsDegradedAndAllDisconnectedIsFailed() async throws {
        let questionAudio = HeldAudio()
        let candidateAudio = HeldAudio()
        let question = InjectedSTT()
        let candidate = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: questionAudio, makeSTT: { question }),
            .init(source: .init(id: "candidate", role: .candidate), audio: candidateAudio, makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await questionAudio.fail()
        try await eventually { await session.current().state == .degraded }
        let degraded = await session.current()
        XCTAssertEqual(degraded.connected, ["candidate"])
        await candidate.send("What is the deadline?", item: "candidate")
        try await eventually { await session.current().transcript.count == 1 }
        let inputs = await classifier.inputs
        XCTAssertTrue(inputs.isEmpty)
        await candidateAudio.fail()
        try await eventually { await session.current().state == .failed }
        let failed = await session.current()
        XCTAssertTrue(failed.connected.isEmpty)
        await session.stop()
    }
}

private actor DelayedFinalSTT: StreamingSTT {
    private var source: CaptureSource?
    private var epoch: UUID?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private(set) var inputEnded = false
    func connect(source: CaptureSource, epoch: UUID) -> AsyncThrowingStream<TranscriptEvent, Error> {
        self.source = source
        self.epoch = epoch
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        return stream
    }
    func append(_ frame: AudioFrame) {}
    func commit() {
        if let source, let epoch {
            output?.yield(.init(source: source, epoch: epoch, itemID: "one", text: "Explain", state: .partial))
        }
    }
    func finishInput() { inputEnded = true }
    func close() { output?.finish(); output = nil }
    func final() {
        if let source, let epoch {
            output?.yield(.init(source: source, epoch: epoch, itemID: "one", text: "Explain the tradeoffs.", state: .final))
        }
    }
}

extension PipelineHardeningTests {
    func testReplayDrainsDelayedFinalAndMeasuresToViewAcknowledgment() async throws {
        let source = CaptureSource(id: "replay", role: .interviewer)
        let audio = PCMReplaySource(source: source, pcm: Data(repeating: 64, count: 9_600), pace: { _ in })
        let stt = DelayedFinalSTT()
        let session = InterviewSession(channels: [
            .init(source: source, audio: audio, replay: true, drainTimeout: .seconds(2), makeSTT: { stt })
        ], detector: .init(classifier: HeldClassifier(slow: false)), generator: FixedAnswer())
        await session.start()
        try await eventually { await stt.inputEnded }
        let beforeFinal = await session.current()
        XCTAssertTrue(beforeFinal.answers.isEmpty)
        await stt.final()
        try await eventually { await session.current().answers.last?.state == .complete }
        let snapshot = await session.current()
        let answer = try XCTUnwrap(snapshot.answers.last)
        XCTAssertNil(answer.pipeline?.endpointToVisible)
        XCTAssertNotNil(answer.pipeline?.commitToFinal)
        XCTAssertNotNil(answer.pipeline?.classification)
        XCTAssertNotNil(answer.pipeline?.retrieval)
        XCTAssertNotNil(answer.pipeline?.requestToToken)
        await session.responseVisible(answer.revision)
        let visible = await session.current()
        XCTAssertNotNil(visible.answers.last?.pipeline?.endpointToVisible)
        await session.stop()
    }

    func testCandidateContextCarriesActualSpeechAndPriorQuestionIdentity() async throws {
        let question = InjectedSTT()
        let candidate = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: HeldAudio(), makeSTT: { question }),
            .init(source: .init(id: "candidate", role: .candidate), audio: HeldAudio(), makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await question.send("Describe your approach.", item: "first")
        try await eventually { await session.current().answers.count == 1 }
        await candidate.send("I split the queue by priority.", item: "actual")
        try await eventually { await session.current().transcript.count == 2 }
        await question.send("Why did you choose that approach?", item: "follow-up")
        try await eventually { await classifier.inputs.count == 2 }
        let inputs = await classifier.inputs
        XCTAssertEqual(inputs.last?.conversation.map(\.role), [.interviewer, .candidate])
        XCTAssertNotNil(inputs.last?.conversation.first?.questionID)
        XCTAssertEqual(inputs.last?.conversation.last?.text, "I split the queue by priority.")
        XCTAssertFalse(inputs.last?.conversation.contains { $0.text.contains("Suggested response") } ?? true)
        await session.stop()
    }
}

extension PipelineHardeningTests {
    func testSwitchingSourcesRejectsOldEpochWhileKeepingExistingTranscript() async throws {
        let original = InjectedSTT()
        let replacement = InjectedSTT()
        let source = CaptureSource(id: "question", role: .interviewer)
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: source, audio: HeldAudio(), makeSTT: { original })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await original.send("Explain the first design.", item: "one")
        try await eventually { await session.current().answers.count == 1 }
        await session.replaceChannels([.init(source: source, audio: HeldAudio(), makeSTT: { replacement })])
        try await eventually { await session.current().state == .listening }
        await original.send("This is from the old stream.", item: "two")
        await replacement.send("Explain the second design.", item: "two")
        try await eventually { await session.current().answers.count == 2 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.transcript.map(\.text), ["Explain the first design.", "Explain the second design."])
        await session.stop()
    }
}

private struct HangingGenerator: TextGenerator {
    func stream(_ request: AnswerRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        try await Task.sleep(for: .seconds(30))
        return AsyncThrowingStream { $0.finish() }
    }
}

extension PipelineHardeningTests {
    func testMultipartConnectorWaitsAndPauseCancelsClassifier() async throws {
        let stt = InjectedSTT()
        let classifier = HeldClassifier()
        let source = CaptureSource(id: "question", role: .interviewer)
        let session = InterviewSession(channels: [.init(source: source, audio: HeldAudio(), makeSTT: { stt })],
                                       detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await stt.send("Explain your approach and", item: "one")
        try await eventually { await session.current().transcript.count == 1 }
        let inputCount = await classifier.inputs.count
        XCTAssertEqual(inputCount, 0)
        await stt.send("how you measured success.", item: "two")
        try await eventually { await classifier.inputs.count == 1 }
        let merged = await classifier.inputs.first?.turn.text
        XCTAssertEqual(merged, "Explain your approach and how you measured success.")
        await session.pause()
        let paused = await session.current()
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(paused.answers.isEmpty)
        await session.start()
        try await eventually { await session.current().state == .listening }
        await session.stop()
    }

    func testGenerationDeadlineDoesNotChangeCaptureLifecycle() async throws {
        let session = InterviewSession(channels: [], detector: .init(classifier: HeldClassifier(slow: false)),
                                       generator: HangingGenerator(), generationTimeout: .milliseconds(20))
        await session.start()
        await session.manualQuestion("Explain deadlines.")
        try await eventually { await session.current().answers.last?.state == .failed }
        let failed = await session.current()
        XCTAssertEqual(failed.state, .degraded)
        XCTAssertTrue(failed.answers.last?.failure?.contains("timed out") == true)
        await session.stop()
    }
}

private actor UnreadySTT: StreamingSTT {
    private(set) var attempted = false
    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        attempted = true
        try await Task.sleep(for: .seconds(30))
        throw ProviderFailure.authentication
    }
    func append(_ frame: AudioFrame) {}
    func commit() {}
    func close() {}
}

private actor ObservedAudio: AudioSource {
    private(set) var started = false
    func start() -> AsyncThrowingStream<AudioFrame, Error> {
        started = true
        return AsyncThrowingStream { $0.finish() }
    }
    func stop() {}
}

extension PipelineHardeningTests {
    func testCaptureNeverStartsBeforeProviderReadinessAndStopCancelsStartup() async throws {
        let audio = ObservedAudio()
        let stt = UnreadySTT()
        let session = InterviewSession(channels: [
            .init(source: .init(id: "question", role: .interviewer), audio: audio, makeSTT: { stt })
        ], detector: .init(classifier: HeldClassifier()), generator: FixedAnswer())
        await session.start()
        try await eventually { await stt.attempted }
        let starting = await session.current()
        XCTAssertEqual(starting.state, .connecting)
        let launched = await audio.started
        XCTAssertFalse(launched)
        await session.stop()
        let stopped = await session.current()
        XCTAssertEqual(stopped.state, .stopped)
        let launchedAfterStop = await audio.started
        XCTAssertFalse(launchedAfterStop)
    }
}

extension PipelineHardeningTests {
    func testProviderAudioRangeMapsToBoundedMonotonicStreamClock() throws {
        let instant = ContinuousClock.now
        let source = CaptureSource(id: "test", role: .interviewer)
        var clock = StreamAudioClock()
        for frame in 0..<100 {
            let simulated = instant.advanced(by: .milliseconds(frame * 20))
            clock.record(.init(source: source, sampleRate: 24_000, startSample: Int64(frame * 480),
                               pcm: Data(repeating: 0, count: 960), capturedAt: simulated))
        }
        let measurement = try XCTUnwrap(clock.measure(.init(startSeconds: 0.2, endSeconds: 1.4)))
        XCTAssertEqual(instant.duration(to: measurement.start), .milliseconds(200))
        XCTAssertEqual(instant.duration(to: measurement.end), .milliseconds(1_400))
        XCTAssertNil(clock.measure(.init(startSeconds: 0, endSeconds: 2.02)))
        XCTAssertNil(clock.measure(.init(startSeconds: .nan, endSeconds: 1)))
    }

    func testCrossSourceAttributionBothOrdersDifferentTextShortSpeechAndRepeat() async throws {
        let remote = InjectedSTT()
        let candidate = InjectedSTT()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "remote", role: .interviewer), audio: HeldAudio(), makeSTT: { remote }),
            .init(source: .init(id: "mic", role: .candidate), audio: HeldAudio(), makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        let origin = ContinuousClock.now.advanced(by: .seconds(-10))
        func time(_ start: Int, _ end: Int) -> PipelineTiming {
            var timing = PipelineTiming()
            timing.speechStart = origin.advanced(by: .milliseconds(start))
            timing.endpoint = origin.advanced(by: .milliseconds(end))
            timing.audioTimingBasis = .providerRangeEstimate
            return timing
        }
        await candidate.send("Why?", item: "short-mic", timing: time(900, 1_100))
        try await eventually { await session.current().transcript.count == 1 }
        await remote.send("Why?", item: "short-remote", timing: time(930, 1_130))
        try await eventually { await session.current().transcript.last?.role == .unknown }
        await remote.send("Explain how you used the queue.", item: "leak-remote", timing: time(2_000, 3_000))
        try await eventually { await session.current().transcript.count == 3 }
        await candidate.send("Explain how you use the queue.", item: "leak-mic", state: .partial, timing: time(2_010, 3_030))
        try await eventually { await session.current().transcript.filter { $0.role == .unknown }.count == 2 }
        await candidate.send("I am taking notes", item: "overlap-mic", timing: time(4_000, 4_900))
        await remote.send("Explain the retry design.", item: "overlap-remote", timing: time(4_450, 5_350))
        try await eventually { await session.current().answers.count == 1 }
        await remote.send("Why?", item: "repeat-remote", timing: time(6_000, 6_200))
        try await eventually { await session.current().answers.count == 2 }
        let inputs = await classifier.inputs.map(\.turn.text)
        XCTAssertEqual(inputs, ["Explain the retry design.", "Why?"])
        let unknown = await session.current().transcript.filter { $0.role == .unknown }.map(\.text)
        XCTAssertEqual(unknown, ["Why?", "Explain how you used the queue."])
        await session.stop()
    }

    func testProviderWatchdogTracksSpeechAndOutOfOrderFinalsWithoutTreatingSilenceAsFailure() async throws {
        let progress = RecognitionProgress(providerCommits: true)
        let source = CaptureSource(id: "remote", role: .interviewer)
        let epoch = UUID()
        let time = ContinuousClock.now
        let frame = AudioFrame(source: source, sampleRate: 24_000, startSample: 24_000,
                               pcm: Data(repeating: 0, count: 144_000), capturedAt: time)
        await progress.sending(frame, voiced: false, now: time)
        let stalledSend = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(6)))
        XCTAssertEqual(stalledSend, .timeout)
        await progress.sent()
        let silence = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(60)))
        XCTAssertNil(silence)
        for (start, end) in [(0, 1), (1, 2)] {
            var speech = PipelineTiming()
            speech.speechStart = time.advanced(by: .seconds(start))
            speech.endpoint = time.advanced(by: .seconds(end))
            try await progress.endedSpeech(speech, now: time.advanced(by: .seconds(end)))
        }
        func final(_ id: String, start: Double, end: Double) -> TranscriptEvent {
            .init(source: source, epoch: epoch, itemID: id, text: id, state: .final,
                  audioRange: .init(startSeconds: start, endSeconds: end))
        }
        let late = await progress.tag(final("second", start: 0.9, end: 2.1))
        let second = try XCTUnwrap(late)
        XCTAssertEqual(second.timing.endpoint, time.advanced(by: .milliseconds(2_100)))
        XCTAssertEqual(second.timing.audioTimingBasis, .providerRangeEstimate)
        XCTAssertNil(second.timing.commit)
        await progress.delivered(second)
        let missingEarlier = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(6)))
        // The second provider range crosses the first utterance by 100 ms; that sliver is not a final for it.
        XCTAssertEqual(missingEarlier, .timeout)
        let early = await progress.tag(final("first", start: 0, end: 1))
        let first = try XCTUnwrap(early)
        XCTAssertEqual(first.timing.endpoint, time.advanced(by: .seconds(1)))
        await progress.delivered(first)
        let clear = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(6)))
        XCTAssertNil(clear)
        let replay = await progress.tag(final("first", start: 0, end: 1))
        XCTAssertNil(replay)
        let reset = await progress.tag(final("reset-item", start: 0, end: 1))
        XCTAssertNil(reset?.timing.endpoint)
        XCTAssertNil(reset?.timing.audioTimingBasis)
    }

    func testClientCommitEmptyFinalAndExplicitStreamAcknowledgmentAreIndependent() async throws {
        let progress = RecognitionProgress(providerCommits: false, requiresStreamEnd: true)
        let time = ContinuousClock.now
        var timing = PipelineTiming()
        timing.commit = time
        try await progress.committed(timing, now: time)
        await progress.sent()
        let missing = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(6)))
        XCTAssertEqual(missing, .timeout)
        let source = CaptureSource(id: "remote", role: .interviewer)
        let raw = TranscriptEvent(source: source, epoch: UUID(), itemID: "empty", text: "", state: .final)
        let event = await progress.tag(raw)
        await progress.delivered(try XCTUnwrap(event))
        let notStalled = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(6)))
        XCTAssertNil(notStalled)
        await progress.requestFinish()
        await progress.finishSent()
        let waiting = await progress.isFinished
        XCTAssertFalse(waiting)
        let drainTimeout = await progress.expired(recognition: .seconds(5), drain: .seconds(2), now: time.advanced(by: .seconds(3)))
        XCTAssertEqual(drainTimeout, .incompleteTranscription)
        let acknowledged = await progress.streamEnded()
        XCTAssertTrue(acknowledged)
        let done = await progress.isFinished
        XCTAssertTrue(done)
    }
}

private actor WatchdogSTT: StreamingSTT {
    nonisolated let behavior = TranscriptionBehavior(delivery: .providerCommit, streamsSilence: true)
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private(set) var epochs: [UUID] = []
    private(set) var submitted: [Int64] = []
    private(set) var heartbeats = 0
    private var connected = true
    func connect(source: CaptureSource, epoch: UUID) -> AsyncThrowingStream<TranscriptEvent, Error> {
        epochs.append(epoch)
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.output = output
        return stream
    }
    func append(_ frame: AudioFrame) { submitted.append(frame.startSample) }
    func commit() {}
    func checkConnection() throws {
        heartbeats += 1
        if !connected { throw ProviderFailure.disconnected }
    }
    func dropWithoutClosingStream() { connected = false }
    func disconnect() { output?.finish(throwing: ProviderFailure.disconnected) }
    func close() { output?.finish(); output = nil }
}

extension PipelineHardeningTests {
    func testStalledProviderRecoversWithFreshEpochNoReplayAndExhaustsRetries() async throws {
        let source = CaptureSource(id: "remote", role: .interviewer)
        let audio = HeldAudio()
        let stt = WatchdogSTT()
        let session = InterviewSession(channels: [
            .init(source: source, audio: audio, recognitionTimeout: .milliseconds(50), makeSTT: { stt }, delay: { _ in })
        ], detector: .init(classifier: HeldClassifier(slow: false)), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        let start = ContinuousClock.now
        await audio.send(.init(source: source, sampleRate: 24_000, startSample: 0,
                               pcm: Data(repeating: 64, count: 960), capturedAt: start))
        await audio.send(.init(source: source, sampleRate: 24_000, startSample: 480,
                               pcm: Data(repeating: 0, count: 24_000), capturedAt: start.advanced(by: .milliseconds(20))))
        try await eventually {
            let snapshot = await session.current()
            return snapshot.state == .listening && snapshot.reconnects == 1
        }
        await stt.disconnect()
        try await eventually {
            let snapshot = await session.current()
            return snapshot.state == .listening && snapshot.reconnects == 2
        }
        await stt.disconnect()
        try await eventually { await session.current().state == .failed }
        let epochs = await stt.epochs
        let submitted = await stt.submitted
        XCTAssertEqual(Set(epochs).count, 3)
        XCTAssertEqual(submitted, [0, 480])
        let snapshot = await session.current()
        XCTAssertTrue(snapshot.issues.last?.contains("attempts exhausted") == true)
        XCTAssertTrue(snapshot.answers.isEmpty)
        await session.stop()
    }

    func testProviderUsageIsCountedOnceAndRejectedForStaleEpoch() async throws {
        let stt = InjectedSTT()
        let session = InterviewSession(channels: [
            .init(source: .init(id: "remote", role: .interviewer), audio: HeldAudio(), makeSTT: { stt })
        ], detector: .init(classifier: HeldClassifier(slow: false)), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        await stt.send("", item: "empty", usage: .audioSeconds(1.25))
        await stt.send("", item: "empty", usage: .audioSeconds(1.25))
        await stt.send("", item: "stale", epoch: UUID(), usage: .audioSeconds(99))
        await stt.send("Explain usage.", item: "visible", usage: .tokens(.init(input: 3, output: 2)))
        try await eventually { await session.current().answers.count == 1 }
        let snapshot = await session.current()
        XCTAssertEqual(snapshot.recognitionSeconds["remote"], 1.25)
        XCTAssertEqual(snapshot.recognitionTokens["remote"], .init(input: 3, output: 2))
        XCTAssertEqual(snapshot.transcript.map(\.text), ["Explain usage."])
        await session.stop()
    }

    func testQuietTransportHeartbeatOnlyFailsWhenDisconnected() async throws {
        let stt = WatchdogSTT()
        let session = InterviewSession(channels: [
            .init(source: .init(id: "remote", role: .interviewer), audio: HeldAudio(),
                  heartbeatInterval: .milliseconds(20), makeSTT: { stt }, delay: { _ in })
        ], detector: .init(classifier: HeldClassifier(slow: false)), generator: FixedAnswer())
        await session.start()
        try await eventually { await stt.heartbeats >= 2 }
        let quiet = await session.current()
        XCTAssertEqual(quiet.state, .listening)
        XCTAssertEqual(quiet.reconnects, 0)
        await stt.dropWithoutClosingStream()
        try await eventually { await session.current().state == .failed }
        let failed = await session.current()
        XCTAssertEqual(failed.reconnects, 2)
        XCTAssertTrue(failed.issues.last?.contains("attempts exhausted") == true)
        await session.stop()
    }

    func testCoincidentMicrophoneSpeechWithoutCandidateRecognitionIsAmbiguous() async throws {
        let remote = InjectedSTT()
        let candidate = InjectedSTT()
        let mic = CaptureSource(id: "mic", role: .candidate)
        let microphone = HeldAudio()
        let classifier = HeldClassifier(slow: false)
        let session = InterviewSession(channels: [
            .init(source: .init(id: "remote", role: .interviewer), audio: HeldAudio(), makeSTT: { remote }),
            .init(source: mic, audio: microphone, makeSTT: { candidate })
        ], detector: .init(classifier: classifier), generator: FixedAnswer())
        await session.start()
        try await eventually { await session.current().state == .listening }
        let start = ContinuousClock.now.advanced(by: .seconds(-2))
        await microphone.send(.init(source: mic, sampleRate: 24_000, startSample: 0,
                                    pcm: Data(repeating: 64, count: 24_000), capturedAt: start))
        var timing = PipelineTiming()
        timing.speechStart = start.advanced(by: .milliseconds(50))
        timing.endpoint = start.advanced(by: .milliseconds(550))
        await remote.send("Explain the transaction.", item: "untagged-echo", timing: timing)
        try await eventually { await session.current().transcript.last?.role == .unknown }
        let inputs = await classifier.inputs
        XCTAssertTrue(inputs.isEmpty)
        let transcript = await session.current().transcript
        XCTAssertEqual(transcript.first?.text, "Explain the transaction.")
        await session.stop()
    }
}
