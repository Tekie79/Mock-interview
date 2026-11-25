#if os(macOS)
import Foundation

/// Chooses the installed SpeechAnalyzer model for strict recognition when present.
public actor AppleSpeechRouter: StreamingSTT {
    private let makeRecognizer: @Sendable () async -> any StreamingSTT
    private var selected: (any StreamingSTT)?
    private var activation: UUID?

    public init(locale: String, mode: AppleRecognitionMode, vocabulary: [String]) {
        makeRecognizer = { await Self.makeRecognizer(locale: locale, mode: mode, vocabulary: vocabulary) }
    }

    init(makeRecognizer: @escaping @Sendable () async -> any StreamingSTT) {
        self.makeRecognizer = makeRecognizer
    }

    public var behavior: TranscriptionBehavior { get async { await selected?.behavior ?? .init() } }

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        try Task.checkCancellation()
        guard activation == nil else { throw CaptureFailure.alreadyRunning }
        let id = UUID()
        activation = id
        do {
            let recognizer = await makeRecognizer()
            try Task.checkCancellation()
            guard activation == id else { throw CancellationError() }
            selected = recognizer
            let results = try await recognizer.connect(source: source, epoch: epoch)
            try Task.checkCancellation()
            guard activation == id else { throw CancellationError() }
            return results
        } catch {
            if activation == id { await close() }
            throw error
        }
    }

    private static func makeRecognizer(locale: String, mode: AppleRecognitionMode,
                                       vocabulary: [String]) async -> any StreamingSTT {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), mode == .onDevice, vocabulary.allSatisfy(\.isEmpty),
           let installed = await MacSpeechAnalyzerTranscriber.installedLocale(for: locale) {
            return MacSpeechAnalyzerTranscriber(locale: installed)
        }
        #endif
        return AppleSpeechTranscriber(locale: locale, mode: mode, vocabulary: vocabulary)
    }

    public func append(_ frame: AudioFrame) async throws {
        try Task.checkCancellation()
        guard let selected else { throw ProviderFailure.disconnected }
        try await selected.append(frame)
    }

    public func commit() async throws {
        try Task.checkCancellation()
        try await selected?.commit()
    }

    public func finishInput() async throws {
        try Task.checkCancellation()
        try await selected?.finishInput()
    }

    public func close() async {
        activation = nil
        let previous = selected
        selected = nil
        await previous?.close()
    }
}
#endif
