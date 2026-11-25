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
    private var state: UUID?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var analysis: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    init(locale: Locale) { self.locale = locale }

    static func installedLocale(for requested: String) async -> Locale? {
        let code = requested.replacingOccurrences(of: "_", with: "-").lowercased()
        return await SpeechTranscriber.installedLocales.first {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == code
        }
    }

    func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard state == nil else { throw CaptureFailure.alreadyRunning }
        guard await AppleSpeechTranscriber.requestRecognitionPermission() else {
            try Task.checkCancellation()
            throw AppleRecognitionFailure.speechPermissionDenied
        }
        let recognizer = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [recognizer])
        guard let common = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: false),
              let required = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer]) else {
            throw AppleRecognitionFailure.onDeviceUnavailable
        }
        let converter = common == required ? nil : AVAudioConverter(from: common, to: required)
        guard common == required || converter != nil else { throw CaptureFailure.invalidFormat }
        try await analyzer.prepareToAnalyze(in: required)
        try Task.checkCancellation()

        let (frames, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.input = input
        self.output = output
        self.analyzer = analyzer
        self.converter = converter
        self.format = common
        self.outputFormat = required
        state = epoch

        analysis = Task.detached {
            do {
                if let end = try await analyzer.analyzeSequence(frames) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                if !Task.isCancelled { output.finish(throwing: ProviderFailure.unavailable) }
            }
        }
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
                                                state: result.isFinal ? .final : .partial, language: language)
                    if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
                }
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch let failure as CaptureFailure {
                output.finish(throwing: failure)
            } catch {
                output.finish(throwing: ProviderFailure.unavailable)
            }
        }
        output.onTermination = { [weak self] _ in
            Task { await self?.close(epoch: epoch) }
        }
        return events
    }

    func append(_ frame: AudioFrame) throws {
        guard let input, let format, let outputFormat, frame.sampleRate == 24_000, !frame.pcm.isEmpty,
              frame.pcm.count.isMultiple(of: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.pcm.count / 2)),
              let samples = buffer.int16ChannelData else { throw CaptureFailure.invalidFormat }
        buffer.frameLength = buffer.frameCapacity
        frame.pcm.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { memcpy(samples[0], source, bytes.count) }
        }
        let audio: AVAudioPCMBuffer
        if let converter {
            let count = ceil(Double(buffer.frameLength) * outputFormat.sampleRate / format.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count + 64))
            else { throw CaptureFailure.invalidFormat }
            var sent = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, next in
                if sent { next.pointee = .noDataNow; return nil }
                sent = true
                next.pointee = .haveData
                return buffer
            }
            guard status != .error else { throw CaptureFailure.invalidFormat }
            audio = converted
        } else {
            audio = buffer
        }
        if audio.frameLength > 0, case .dropped = input.yield(AnalyzerInput(buffer: audio)) {
            throw CaptureFailure.bufferOverrun
        }
    }

    func commit() {}
    func finishInput() { input?.finish() }

    func close() async {
        state = nil
        input?.finish()
        input = nil
        let oldAnalysis = analysis
        let oldReader = reader
        let oldAnalyzer = analyzer
        analysis = nil
        reader = nil
        analyzer = nil
        oldAnalysis?.cancel()
        oldReader?.cancel()
        output?.finish()
        output = nil
        await oldAnalyzer?.cancelAndFinishNow()
        await oldAnalysis?.value
        await oldReader?.value
    }

    private func close(epoch: UUID) async {
        if state == epoch { await close() }
    }
}
#endif
