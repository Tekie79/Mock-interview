#if os(macOS)
import AVFoundation
import Foundation
import Speech

public actor AppleSpeechTranscriber: StreamingSTT {
    private struct Recognition {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    private let locale: String
    private let mode: AppleRecognitionMode
    private let vocabulary: [String]
    private var recognizer: SFSpeechRecognizer?
    private var identity: (source: CaptureSource, epoch: UUID)?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
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

    public func connect(source: CaptureSource, epoch: UUID) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard identity == nil else { throw CaptureFailure.alreadyRunning }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard authorization == .authorized else { throw AppleRecognitionFailure.speechPermissionDenied }
        let available = Self.hasOnDeviceRecognition(locale: locale)
        try AppleRecognitionPolicy.validate(language: locale, supported: Set(Self.languages()),
                                            mode: mode, onDeviceAvailable: available)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw ProviderFailure.unavailable
        }
        self.recognizer = recognizer
        identity = (source, epoch)
        let (stream, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.output = output
        output.onTermination = { [weak self] _ in Task { await self?.close(epoch: epoch) } }
        return stream
    }

    public func append(_ frame: AudioFrame) throws {
        guard !finishing, let identity, frame.source == identity.source, frame.sampleRate == 24_000,
              !frame.pcm.isEmpty, frame.pcm.count.isMultiple(of: 2),
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
        finishing = true
        commit()
        if requests.isEmpty { output?.finish() }
    }

    public func close() {
        identity = nil
        active = nil
        for recognition in requests.values { recognition.task.cancel() }
        requests.removeAll()
        finals.removeAll()
        output?.finish()
        output = nil
        recognizer = nil
        finishing = false
        nextSequence = 0
        publishing = 0
    }

    private func close(epoch: UUID) {
        if identity?.epoch == epoch { close() }
    }

    private func startRequest() throws {
        guard requests.count < 4, nextSequence - publishing < 8, let identity, let recognizer else {
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
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription
            let words = transcript?.segments.prefix(1_024).map { segment in
                TranscriptWord(text: segment.substring, startSeconds: segment.timestamp,
                               endSeconds: segment.timestamp + segment.duration)
            } ?? []
            let text = transcript?.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task {
                await self?.receive(index: index, epoch: identity.epoch, text: text, words: words,
                                    final: final, failed: failed)
            }
        }
        requests[index] = Recognition(request: request, task: task)
        active = index
    }

    private func receive(index: Int, epoch: UUID, text: String?, words: [TranscriptWord], final: Bool, failed: Bool) {
        guard let identity, identity.epoch == epoch, requests[index] != nil else { return }
        if failed && !final {
            output?.finish(throwing: ProviderFailure.unavailable)
            return
        }
        guard let text else { return }
        let id = "apple-\(index)"
        let event = TranscriptEvent(source: identity.source, epoch: epoch, itemID: id,
                                    previousItemID: index > 0 ? "apple-\(index - 1)" : nil,
                                    text: String(text.prefix(8_000)), state: final ? .final : .partial,
                                    words: words, language: locale)
        if final {
            if active == index {
                // A system recognition limit interrupted still-open audio. Start a fresh epoch.
                output?.finish(throwing: ProviderFailure.incompleteTranscription)
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
