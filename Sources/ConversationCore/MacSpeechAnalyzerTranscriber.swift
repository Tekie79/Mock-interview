#if os(macOS) && compiler(>=6.2)
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// The installed-model API on macOS 26 and later. This path never downloads assets.
@available(macOS 26.0, *)
actor MacSpeechAnalyzerTranscriber: StreamingSTT {
    nonisolated let behavior = TranscriptionBehavior(delivery: .providerCommit, streamsSilence: true)
    private let locale: Locale
    private var activation: UUID?
    private var source: CaptureSource?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var analysis: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: NativePCMConverter?

    init(locale: Locale) { self.locale = locale }

    static func installedLocale(for requested: String) async -> Locale? {
        let code = requested.replacingOccurrences(of: "_", with: "-").lowercased()
        return await SpeechTranscriber.installedLocales.first {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == code
        }
    }

    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        try Task.checkCancellation()
        guard activation == nil else { throw CaptureFailure.alreadyRunning }
        let id = UUID()
        activation = id
        var connected = false
        defer {
            if !connected, activation == id { activation = nil }
        }
        let allowed = await AppleSpeechTranscriber.requestRecognitionPermission()
        try Task.checkCancellation()
        guard activation == id else { throw CancellationError() }
        guard allowed else { throw AppleRecognitionFailure.speechPermissionDenied }
        let recognizer = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [recognizer])
        let required = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer])
        try Task.checkCancellation()
        guard activation == id else { throw CancellationError() }
        guard let common = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: false),
              let required else {
            throw AppleRecognitionFailure.onDeviceUnavailable
        }
        let converter = common == required ? nil : try NativePCMConverter(from: common, to: required)
        try await analyzer.prepareToAnalyze(in: required)
        try Task.checkCancellation()
        guard activation == id else { throw CancellationError() }

        let (frames, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.input = input
        self.output = output
        self.analyzer = analyzer
        self.converter = converter
        self.format = common
        self.source = source

        output.onTermination = { [weak self] _ in Task { await self?.close(id) } }
        let analysis = Task.detached {
            do {
                let end = try await analyzer.analyzeSequence(frames)
                try Task.checkCancellation()
                if let end {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                if !Task.isCancelled { output.finish(throwing: ProviderFailure.unavailable) }
            }
        }
        self.analysis = analysis
        let language = locale.identifier
        reader = Task.detached {
            var completed: Set<String> = []
            do {
                for try await result in recognizer.results {
                    try Task.checkCancellation()
                    let start = result.range.start
                    let id = "apple-analyzer-\(start.value)/\(start.timescale)"
                    guard !completed.contains(id) else { continue }
                    if result.isFinal {
                        guard completed.count < 32_768 else { throw ProviderFailure.incompleteTranscription }
                        completed.insert(id)
                    }
                    let text = String(String(result.text.characters).prefix(8_000))
                    let event = TranscriptEvent(source: source, epoch: epoch, itemID: id, text: text,
                                                state: result.isFinal ? .final : .partial, language: language,
                                                audioRange: .init(startSeconds: CMTimeGetSeconds(start),
                                                                  endSeconds: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))))
                    switch output.yield(event) {
                    case .enqueued: break
                    case .terminated: return
                    case .dropped: throw CaptureFailure.bufferOverrun
                    @unknown default: throw ProviderFailure.incompleteTranscription
                    }
                }
                await analysis.value
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch let failure as CaptureFailure {
                output.finish(throwing: failure)
            } catch {
                output.finish(throwing: ProviderFailure.unavailable)
            }
        }
        connected = true
        return events
    }

    func append(_ frame: AudioFrame) throws {
        try Task.checkCancellation()
        guard let input, let source, let format else { throw ProviderFailure.disconnected }
        guard frame.source == source, frame.sampleRate == 24_000, !frame.pcm.isEmpty,
              frame.pcm.count.isMultiple(of: 2), frame.pcm.count / 2 <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.pcm.count / 2)),
              let samples = buffer.int16ChannelData else { throw CaptureFailure.invalidFormat }
        buffer.frameLength = buffer.frameCapacity
        frame.pcm.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { memcpy(samples[0], source, bytes.count) }
        }
        try send(try converter?.convert(buffer) ?? buffer, into: input)
    }

    func commit() {}

    func finishInput() throws {
        try Task.checkCancellation()
        guard let input else { return }
        self.input = nil
        defer { input.finish() }
        do {
            while let audio = try converter?.drain() {
                try Task.checkCancellation()
                try send(audio, into: input)
            }
        } catch {
            output?.finish(throwing: error)
            throw error
        }
    }

    private func send(_ audio: AVAudioPCMBuffer, into input: AsyncStream<AnalyzerInput>.Continuation) throws {
        guard audio.frameLength > 0 else { return }
        switch input.yield(AnalyzerInput(buffer: audio)) {
        case .enqueued: break
        case .terminated: throw ProviderFailure.disconnected
        case .dropped: throw CaptureFailure.bufferOverrun
        @unknown default: throw ProviderFailure.incompleteTranscription
        }
    }

    func close() async {
        activation = nil
        source = nil
        format = nil
        converter = nil
        let oldInput = input
        input = nil
        let oldAnalysis = analysis
        let oldReader = reader
        let oldAnalyzer = analyzer
        analysis = nil
        reader = nil
        analyzer = nil
        oldAnalysis?.cancel()
        oldReader?.cancel()
        oldInput?.finish()
        output?.finish()
        output = nil
        await oldAnalyzer?.cancelAndFinishNow()
        await oldAnalysis?.value
        await oldReader?.value
    }

    private func close(_ id: UUID) async {
        if activation == id { await close() }
    }
}
#endif
