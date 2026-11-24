import Foundation

public enum AnswerFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case ultraBrief = "Ultra-brief"
    case brief = "Brief"
    case standard = "Standard"
    case detailed = "Detailed"
    case bullets = "Talking points"
    case star = "STAR"
    case technical = "Technical"

    public var id: String { rawValue }

    var instruction: String {
        switch self {
        case .ultraBrief: "Use one or two sentences."
        case .brief: "Use three to five sentences, roughly 45 to 85 words."
        case .standard: "Aim for 100 to 150 words."
        case .detailed: "Use up to 250 words."
        case .bullets: "Use concise talking points."
        case .star: "Use situation, task, action, and result sections when appropriate."
        case .technical: "Use a short technical example or pseudocode where useful. Do not claim it was tested."
        }
    }
}

public struct InterviewAnswer: Identifiable, Sendable, Codable, Equatable {
    public enum State: String, Codable, Sendable {
        case generating, complete, cancelled, superseded, failed
    }

    public let question: AcceptedQuestion
    public let revision: UUID
    public let format: AnswerFormat
    public var text: String
    public var state: State
    public var evidence: [String] = []
    public var id: UUID { question.id }
}

public struct InterviewTranscript: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let role: SourceRole
    public var text: String
    public var isFinal: Bool
}

public struct InterviewSnapshot: Sendable {
    public enum State: String, Sendable {
        case idle, listening, paused, stopped
    }

    public internal(set) var state: State = .idle
    public internal(set) var transcript: [InterviewTranscript] = []
    public internal(set) var answers: [InterviewAnswer] = []
    public internal(set) var levels: [String: Float] = [:]
    public internal(set) var connected: Set<String> = []
    public internal(set) var issues: [String] = []
}

public actor InterviewSession {
    private let channels: [TranscriptionChannel]
    private let detector: QuestionDetector
    private let generator: any TextGenerator
    private let preferences: String
    private let evidence: @Sendable (String) async -> [String]
    private var captureID: UUID?
    private var cleanup: Task<Void, Never>?
    private var captureTasks: [Task<Void, Never>] = []
    private var epochs: [String: UUID] = [:]
    private var generation: Task<Void, Never>?
    private var activeRevision: UUID?
    private var format: AnswerFormat
    private var snapshot = InterviewSnapshot()
    private var subscriber: AsyncStream<InterviewSnapshot>.Continuation?

    public init(channels: [TranscriptionChannel], detector: QuestionDetector, generator: any TextGenerator,
                format: AnswerFormat = .brief, preferences: String = "",
                evidence: @escaping @Sendable (String) async -> [String] = { _ in [] }) {
        self.channels = channels
        self.detector = detector
        self.generator = generator
        self.format = format
        self.preferences = preferences
        self.evidence = evidence
    }

    public func updates() -> AsyncStream<InterviewSnapshot> {
        subscriber?.finish()
        let (stream, output) = AsyncStream<InterviewSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscriber = output
        output.yield(snapshot)
        return stream
    }

    public func current() -> InterviewSnapshot { snapshot }

    public func start() {
        guard cleanup == nil, snapshot.state == .idle || snapshot.state == .paused else { return }
        let id = UUID()
        captureID = id
        snapshot.state = .listening
        snapshot.issues.removeAll()
        for channel in channels {
            captureTasks.append(Task { [weak self] in
                do {
                    try await channel.run { [weak self] event in
                        await self?.receive(event, activation: id)
                    }
                    await self?.channelEnded(channel.source, activation: id, failed: false)
                } catch {
                    await self?.channelEnded(channel.source, activation: id, failed: !Task.isCancelled)
                }
            })
        }
        publish()
    }

    public func pause() async {
        guard snapshot.state == .listening else { return }
        await endCapture(.paused)
    }

    public func stop() async {
        if snapshot.state == .stopped {
            await cleanup?.value
        } else {
            await endCapture(.stopped)
        }
    }

    public func setFormat(_ format: AnswerFormat) { self.format = format }

    public func manualQuestion(_ text: String) {
        guard captureID != nil else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        generate(AcceptedQuestion(original: question, normalized: question), format: format)
    }

    public func regenerate(_ id: UUID, format: AnswerFormat? = nil) {
        guard captureID != nil,
              let answer = snapshot.answers.first(where: { $0.id == id }) else { return }
        generate(answer.question, format: format ?? answer.format)
    }

    public func cancelAnswer() {
        invalidateAnswer(.cancelled)
        publish()
    }

    private func endCapture(_ state: InterviewSnapshot.State) async {
        if let cleanup {
            if state == .stopped { snapshot.state = .stopped }
            await cleanup.value
            return
        }
        captureID = nil
        epochs.removeAll()
        let tasks = captureTasks
        captureTasks.removeAll()
        for task in tasks { task.cancel() }
        let previous = generation
        invalidateAnswer(.cancelled)
        snapshot.state = state
        cleanup = Task {
            await detector.invalidateAll(keepingContext: state == .paused)
            for task in tasks { await task.value }
            await previous?.value
            snapshot.connected.removeAll()
            snapshot.levels.removeAll()
            snapshot.transcript.removeAll { !$0.isFinal }
            publish()
            if snapshot.state == .stopped {
                subscriber?.finish()
                subscriber = nil
            }
            cleanup = nil
        }
        await cleanup?.value
    }

    private func receive(_ event: ChannelEvent, activation: UUID) async {
        guard captureID == activation else { return }
        switch event {
        case .connected(let source, let epoch):
            epochs[source.id] = epoch
            snapshot.connected.insert(source.id)
            await detector.connect(source, epoch: epoch)
        case .gap(let source):
            epochs.removeValue(forKey: source.id)
            snapshot.connected.remove(source.id)
            recordIssue("Audio gap on " + source.id + ". Reconnecting.")
            if source.role == .interviewer { invalidateAnswer(.cancelled) }
            await detector.invalidate(source)
        case .level(let source, let value):
            snapshot.levels[source.id] = value
        case .transcript(let event):
            guard epochs[event.source.id] == event.epoch else { return }
            let id = event.epoch.uuidString + "/" + event.source.id + "/" + event.itemID
            let item = InterviewTranscript(id: id, role: event.source.role, text: event.text,
                                           isFinal: event.state == .final)
            if let existing = snapshot.transcript.firstIndex(where: { $0.id == id }) {
                if snapshot.transcript[existing].isFinal { return }
                snapshot.transcript[existing] = item
            } else {
                snapshot.transcript.append(item)
                if snapshot.transcript.count > 2_000 { snapshot.transcript.removeFirst() }
            }
            publish()
            do {
                if let question = try await detector.receive(event), captureID == activation,
                   epochs[event.source.id] == event.epoch {
                    generate(question, format: format)
                }
            } catch where !(error is CancellationError) {
                if captureID == activation { recordIssue("Question classification failed. Select transcript text to ask manually.") }
            } catch {}
        }
        if captureID == activation { publish() }
    }

    private func channelEnded(_ source: CaptureSource, activation: UUID, failed: Bool) async {
        guard captureID == activation else { return }
        epochs.removeValue(forKey: source.id)
        snapshot.connected.remove(source.id)
        snapshot.levels.removeValue(forKey: source.id)
        if failed { recordIssue("Capture or transcription stopped on " + source.id + ".") }
        await detector.invalidate(source)
        if captureID == activation { publish() }
    }

    private func generate(_ question: AcceptedQuestion, format: AnswerFormat) {
        invalidateAnswer(.superseded)
        let revision = UUID()
        activeRevision = revision
        let answer = InterviewAnswer(question: question, revision: revision, format: format,
                                     text: "", state: .generating)
        if let index = snapshot.answers.firstIndex(where: { $0.id == question.id }) {
            snapshot.answers[index] = answer
        } else {
            snapshot.answers.append(answer)
            if snapshot.answers.count > 500 { snapshot.answers.removeFirst() }
        }
        publish()
        generation = Task { [weak self, generator, evidence, preferences] in
            do {
                let facts = await evidence(question.normalized)
                try Task.checkCancellation()
                await self?.recordEvidence(facts, revision)
                let text = ([question.normalized] + question.parts).joined(separator: "\n")
                let request = AnswerRequest(question: text,
                                            instructions: format.instruction + " " + preferences,
                                            evidence: facts)
                for try await delta in try await generator.stream(request) {
                    try Task.checkCancellation()
                    await self?.append(delta, revision)
                }
                await self?.complete(revision, state: .complete)
            } catch is CancellationError {
                await self?.complete(revision, state: .cancelled)
            } catch {
                await self?.complete(revision, state: .failed)
            }
        }
    }

    private func recordEvidence(_ evidence: [String], _ revision: UUID) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        snapshot.answers[index].evidence = evidence
        publish()
    }

    private func append(_ delta: String, _ revision: UUID) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        guard snapshot.answers[index].text.utf8.count + delta.utf8.count <= 32_768 else {
            invalidateAnswer(.failed)
            publish()
            return
        }
        snapshot.answers[index].text.append(delta)
        publish()
    }

    private func complete(_ revision: UUID, state: InterviewAnswer.State) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        snapshot.answers[index].state = state == .complete && snapshot.answers[index].text.isEmpty ? .failed : state
        activeRevision = nil
        generation = nil
        publish()
    }

    private func invalidateAnswer(_ state: InterviewAnswer.State) {
        if let activeRevision, let index = snapshot.answers.firstIndex(where: { $0.revision == activeRevision }) {
            snapshot.answers[index].state = state
        }
        activeRevision = nil
        generation?.cancel()
        generation = nil
    }

    private func recordIssue(_ issue: String) {
        snapshot.issues.append(issue)
        if snapshot.issues.count > 20 { snapshot.issues.removeFirst() }
    }

    private func publish() { subscriber?.yield(snapshot) }
}
