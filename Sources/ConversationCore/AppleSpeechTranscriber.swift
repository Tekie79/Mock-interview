#if os(macOS)
import AVFoundation
import Foundation
import Speech

public actor AppleSpeechTranscriber: StreamingSTT {
    public nonisolated let behavior = TranscriptionBehavior(requiresStreamEnd: true)

    private struct Recognition {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    private struct Update: Sendable {
        let index: Int
        let text: String?
        let words: [TranscriptWord]
        let final: Bool
        let failed: Bool
    }

    private let locale: String
    private let mode: AppleRecognitionMode
    private let vocabulary: [String]
    private var recognizer: SFSpeechRecognizer?
    private var activation: UUID?
    private var identity: (source: CaptureSource, epoch: UUID)?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var callbacks: AsyncStream<Update>.Continuation?
    private var reader: Task<Void, Never>?
    private var active: Int?
    private var requests: [Int: Recognition] = [:]
    private var finals: [Int: TranscriptEvent] = [:]
    private var nextSequence = 0
    private var publishing = 0
    private var finishing = false

    public init(locale: String = "en-US", mode: AppleRecognitionMode = .onDevice, vocabulary: [String] = []) {
        self.locale = locale
        self.mode = mode
        self.vocabulary = Array(vocabulary.filter { !$0.isEmpty }.prefix(100)).map { String($0.prefix(80)) }
    }

    public static func languages() -> [String] {
        SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") }.sorted()
    }

    public static func hasOnDeviceRecognition(locale: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true
    }

    static func requestRecognitionPermission() async -> Bool {
        let permissions = AsyncStream<SFSpeechRecognizerAuthorizationStatus> { output in
            SFSpeechRecognizer.requestAuthorization {
                output.yield($0)
                output.finish()
            }
        }
        var responses = permissions.makeAsyncIterator()
        return await responses.next() == .authorized
    }

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        try Task.checkCancellation()
        guard activation == nil else { throw CaptureFailure.alreadyRunning }
        let id = UUID()
        activation = id
        var connected = false
        defer {
            if !connected, activation == id { activation = nil }
        }
        let authorized = await Self.requestRecognitionPermission()
        try Task.checkCancellation()
        guard activation == id else { throw CancellationError() }
        guard authorized else { throw AppleRecognitionFailure.speechPermissionDenied }
        let available = Self.hasOnDeviceRecognition(locale: locale)
        try AppleRecognitionPolicy.validate(language: locale, supported: Set(Self.languages()),
                                            mode: mode, onDeviceAvailable: available)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw ProviderFailure.unavailable
        }
        self.recognizer = recognizer
        identity = (source, epoch)
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let (updates, callbacks) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.output = output
        self.callbacks = callbacks
        output.onTermination = { [weak self] _ in Task { await self?.close(id) } }
        reader = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                await self?.receive(update, activationID: id)
            }
        }
        connected = true
        return stream
    }

    public func append(_ frame: AudioFrame) throws {
        try Task.checkCancellation()
        guard !finishing, let identity else { throw ProviderFailure.disconnected }
        guard frame.source == identity.source, frame.sampleRate == 24_000,
              !frame.pcm.isEmpty, frame.pcm.count.isMultiple(of: 2), frame.pcm.count / 2 <= Int(UInt32.max),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(frame.sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.pcm.count / 2)),
              let samples = buffer.int16ChannelData else { throw CaptureFailure.invalidFormat }
        buffer.frameLength = buffer.frameCapacity
        frame.pcm.withUnsafeBytes { raw in
            if let source = raw.baseAddress { memcpy(samples[0], source, raw.count) }
        }
        if active == nil { try startRequest() }
        guard let active, let request = requests[active]?.request else { throw ProviderFailure.unavailable }
        request.append(buffer)
    }

    public func commit() {
        guard let active else { return }
        requests[active]?.request.endAudio()
        self.active = nil
    }

    public func finishInput() {
        guard identity != nil else { return }
        finishing = true
        commit()
        if requests.isEmpty { output?.finish() }
    }

    public func close() async {
        activation = nil
        identity = nil
        active = nil
        let oldReader = reader
        reader = nil
        oldReader?.cancel()
        callbacks?.finish()
        callbacks = nil
        for recognition in requests.values { recognition.task.cancel() }
        requests.removeAll()
        finals.removeAll()
        output?.finish()
        output = nil
        recognizer = nil
        finishing = false
        nextSequence = 0
        publishing = 0
        await oldReader?.value
    }

    private func close(_ id: UUID) async {
        if activation == id { await close() }
    }

    private func startRequest() throws {
        guard requests.count < 4, nextSequence - publishing < 8, let recognizer, let callbacks, let output else {
            throw ProviderFailure.incompleteTranscription
        }
        if mode == .onDevice && !recognizer.supportsOnDeviceRecognition {
            throw AppleRecognitionFailure.onDeviceUnavailable
        }
        let index = nextSequence
        nextSequence += 1
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = mode == .onDevice
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary
        let handler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            let transcript = result?.bestTranscription
            let words = transcript?.segments.prefix(1_024).map { segment in
                TranscriptWord(text: String(segment.substring.prefix(256)), startSeconds: segment.timestamp,
                               endSeconds: segment.timestamp + segment.duration)
            } ?? []
            let update = Update(index: index, text: transcript.map { String($0.formattedString.prefix(8_000)) },
                                words: words, final: result?.isFinal ?? false, failed: error != nil)
            if case .dropped = callbacks.yield(update) {
                output.finish(throwing: CaptureFailure.bufferOverrun)
                callbacks.finish()
            }
        }
        let task = recognizer.recognitionTask(with: request, resultHandler: handler)
        requests[index] = Recognition(request: request, task: task)
        active = index
    }

    private func receive(_ update: Update, activationID: UUID) {
        let index = update.index
        guard activation == activationID, let identity, requests[index] != nil else { return }
        if update.failed && !update.final {
            output?.finish(throwing: ProviderFailure.unavailable)
            return
        }
        guard let text = update.text else { return }
        let id = "apple-\(index)"
        let event = TranscriptEvent(source: identity.source, epoch: identity.epoch, itemID: id,
                                    previousItemID: index > 0 ? "apple-\(index - 1)" : nil,
                                    text: text, state: update.final ? .final : .partial,
                                    words: update.words, language: locale)
        if update.final {
            if active == index {
                // A system recognition limit interrupted still-open audio. Start a fresh epoch.
                output?.finish(throwing: ProviderFailure.unavailable)
                return
            }
            requests.removeValue(forKey: index)
            finals[index] = event
            while let next = finals.removeValue(forKey: publishing) {
                emit(next)
                publishing += 1
            }
            if finishing && requests.isEmpty { output?.finish() }
        } else {
            emit(event)
        }
    }

    private func emit(_ event: TranscriptEvent) {
        if case .dropped = output?.yield(event) { output?.finish(throwing: CaptureFailure.bufferOverrun) }
    }
}
#endif
