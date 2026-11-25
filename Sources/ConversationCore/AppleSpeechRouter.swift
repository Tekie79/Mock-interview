#if os(macOS)
import Foundation

/// Chooses the installed SpeechAnalyzer model for strict recognition when present.
public actor AppleSpeechRouter: StreamingSTT {
    private let locale: String
    private let mode: AppleRecognitionMode
    private let vocabulary: [String]
    private var selected: (any StreamingSTT)?
    private var activation: UUID?

    public init(locale: String, mode: AppleRecognitionMode, vocabulary: [String]) {
        self.locale = locale
        self.mode = mode
        self.vocabulary = vocabulary
    }

    public var behavior: TranscriptionBehavior { get async { await selected?.behavior ?? .init() } }

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard activation == nil else { throw CaptureFailure.alreadyRunning }
        activation = epoch
        let recognizer = await makeRecognizer()
        guard activation == epoch else { throw CancellationError() }
        selected = recognizer
        do {
            let results = try await recognizer.connect(source: source, epoch: epoch)
            guard activation == epoch else { throw CancellationError() }
            return results
        } catch {
            if activation == epoch { await close() }
            throw error
        }
    }

    private func makeRecognizer() async -> any StreamingSTT {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), mode == .onDevice, vocabulary.allSatisfy(\.isEmpty),
           let installed = await MacSpeechAnalyzerTranscriber.installedLocale(for: locale) {
            return MacSpeechAnalyzerTranscriber(locale: installed)
        }
        #endif
        return AppleSpeechTranscriber(locale: locale, mode: mode, vocabulary: vocabulary)
    }

    public func append(_ frame: AudioFrame) async throws {
        guard let selected else { throw ProviderFailure.disconnected }
        try await selected.append(frame)
    }

    public func commit() async throws { try await selected?.commit() }
    public func finishInput() async throws { try await selected?.finishInput() }

    public func close() async {
        activation = nil
        let previous = selected
        selected = nil
        await previous?.close()
    }
}
#endif
