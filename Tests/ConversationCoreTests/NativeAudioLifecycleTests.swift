#if os(macOS)
import AVFoundation
import XCTest
@testable import ConversationCore

final class NativeAudioLifecycleTests: XCTestCase {
    func testNativeConverterPreservesSampleCountAcrossInputAndEndOfStream() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                channels: 1, interleaved: false))
        let destination = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                                     channels: 1, interleaved: true))
        let converter = try NativePCMConverter(from: source, to: destination)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 960))
        let samples = try XCTUnwrap(input.int16ChannelData)
        input.frameLength = 960
        for sample in 0..<960 { samples[0][sample] = 1_000 }

        var convertedFrames = 0
        for _ in 0..<4 {
            convertedFrames += Int(try converter.convert(input).frameLength)
        }
        var drainedFrames = 0
        while let tail = try converter.drain() {
            drainedFrames += Int(tail.frameLength)
            guard drainedFrames <= 1_920 else { return XCTFail("The converter drained more data than it received") }
        }
        XCTAssertEqual(convertedFrames + drainedFrames, 1_920)
        XCTAssertThrowsError(try converter.convert(input))
    }

    func testNativeDownmixIncludesRightChannel() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                              channels: 1, interleaved: true))
        let converter = try NativePCMConverter(from: stereo, to: mono)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480))
        let samples = try XCTUnwrap(input.floatChannelData)
        input.frameLength = 480
        for sample in 0..<480 {
            samples[0][sample] = 0
            samples[1][sample] = 0.5
        }
        let result = try converter.convert(input)
        let downmixed = try XCTUnwrap(result.int16ChannelData)
        guard result.frameLength == 480 else { return XCTFail("Unexpected downmix length: \(result.frameLength)") }
        XCTAssertGreaterThan(downmixed[0][240], 0)
    }

    func testFramesFromOneNativeCallbackHaveDistinctSampleTimes() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                                channels: 1, interleaved: false))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        input.frameLength = 960
        let samples = try XCTUnwrap(input.int16ChannelData)
        for sample in 0..<960 { samples[0][sample] = 1_000 }
        let observed = ContinuousClock.now
        var encoder = PCMEncoder(source: .init(id: "interviewer", role: .interviewer))
        let first = try encoder.convert(input, capturedAt: observed)
        let second = try encoder.convert(input, capturedAt: observed.advanced(by: .milliseconds(45)))
        XCTAssertEqual((first + second).map(\.startSample), [0, 480, 960, 1_440])
        XCTAssertEqual((first + second).map { observed.duration(to: $0.capturedAt) },
                       [.milliseconds(-40), .milliseconds(-20), .zero, .milliseconds(20)])
    }

    func testExplicitUnpluggedOutputDoesNotFallBackToDefault() async throws {
        let capture = MacAudioSource(source: .init(id: "interviewer", role: .interviewer),
                                     input: .output(uid: UUID().uuidString))
        for _ in 0..<2 {
            do {
                _ = try await capture.start()
                await capture.stop()
                XCTFail("An unknown explicit UID must not start capture")
            } catch let error as CaptureFailure {
                XCTAssertEqual(error, .sourceUnavailable)
            }
        }
    }

    func testOldSpeechConnectionCannotWinWhenCallerReusesEpoch() async throws {
        let stale = PausedNativeRecognizer(suspended: true)
        let current = PausedNativeRecognizer(suspended: false)
        let fixtures = NativeRecognizerFixtures([stale, current])
        let router = AppleSpeechRouter { await fixtures.next() }
        let source = CaptureSource(id: "interviewer", role: .interviewer)
        let epoch = UUID()
        let oldConnection = Task { try await router.connect(source: source, epoch: epoch) }
        var readiness = stale.entered.makeAsyncIterator()
        _ = await readiness.next()
        await router.close()

        _ = try await router.connect(source: source, epoch: epoch)
        await stale.release()
        do {
            _ = try await oldConnection.value
            XCTFail("An acknowledgement from a closed activation must be discarded")
        } catch is CancellationError {}
        try await router.append(.init(source: source, sampleRate: 24_000, startSample: 0, pcm: Data([0, 0])))
        let currentFrames = await current.appendedFrames
        let staleFrames = await stale.appendedFrames
        XCTAssertEqual(currentFrames, 1)
        XCTAssertEqual(staleFrames, 0)
        await router.close()
    }

    func testCancelledSpeechConnectionClosesSelectedRecognizer() async {
        let recognizer = PausedNativeRecognizer(suspended: true)
        let router = AppleSpeechRouter { recognizer }
        let source = CaptureSource(id: "interviewer", role: .interviewer)
        let connection = Task { try await router.connect(source: source, epoch: UUID()) }
        var readiness = recognizer.entered.makeAsyncIterator()
        _ = await readiness.next()
        connection.cancel()
        await recognizer.release()
        do {
            _ = try await connection.value
            XCTFail("A cancelled connection must not publish readiness")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        let closed = await recognizer.closed
        XCTAssertTrue(closed)
    }
}

private actor NativeRecognizerFixtures {
    private var fixtures: [PausedNativeRecognizer]
    init(_ fixtures: [PausedNativeRecognizer]) { self.fixtures = fixtures }
    func next() -> PausedNativeRecognizer { fixtures.removeFirst() }
}

private actor PausedNativeRecognizer: StreamingSTT {
    nonisolated let entered: AsyncStream<Void>
    private let ready: AsyncStream<Void>.Continuation
    private let suspended: Bool
    private var resume: CheckedContinuation<Void, Never>?
    private(set) var appendedFrames = 0
    private(set) var closed = false

    init(suspended: Bool) {
        self.suspended = suspended
        (entered, ready) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    }

    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        if suspended {
            await withCheckedContinuation { continuation in
                resume = continuation
                ready.yield(())
            }
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func release() {
        resume?.resume()
        resume = nil
    }

    func append(_ frame: AudioFrame) { appendedFrames += 1 }
    func commit() {}
    func close() { closed = true }
}
#endif
