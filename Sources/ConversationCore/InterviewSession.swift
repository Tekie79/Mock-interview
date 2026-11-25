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
        case generating, complete, cancelled, superseded, failed, invalidated
    }

    public enum Origin: Codable, Equatable, Sendable {
        case automatic(AutomaticProvenance)
        case manual
    }

    public struct AutomaticProvenance: Codable, Equatable, Sendable {
        public let sourceID: String
        public let captureEpoch: UUID
        public let transcriptID: String
        public let contributingTranscriptIDs: [String]
        public let questionID: UUID
        public let speaker: Int?
    }

    public let question: AcceptedQuestion
    public let revision: UUID
    public let format: AnswerFormat
    public var text: String
    public var state: State
    public var evidence: [String] = []
    public var usage: TokenUsage?
    public var firstTextMilliseconds: Int?
    public var pipeline: PipelineDurations?
    public var failure: String?
    public internal(set) var origin: Origin? = nil
    public var id: UUID { question.id }

    public var originLabel: String? {
        switch origin {
        case .automatic: "Automatic answer"
        case .manual: "Manual answer"
        case nil: nil
        }
    }

    var automaticProvenance: AutomaticProvenance? {
        if case .automatic(let provenance) = origin { return provenance }
        return nil
    }
}

public struct InterviewTranscript: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public internal(set) var role: SourceRole
    public var text: String
    public var isFinal: Bool
    public var timestamp: Date?
    public var speaker: Int?

    public init(id: String, role: SourceRole, text: String, isFinal: Bool, timestamp: Date? = .now,
                speaker: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.speaker = speaker
    }
}

public struct DiarizedSpeaker: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sourceID: String
        public let epoch: UUID
        public let number: Int
    }

    public let id: ID
    public var role: SourceRole
}

public enum LiveState: String, Sendable {
    case idle, connecting, listening, degraded, reconnecting, pausing, paused, stopping, stopped, failed

    public var isRunning: Bool {
        switch self {
        case .connecting, .listening, .degraded, .reconnecting: true
        default: false
        }
    }
}

public struct InterviewSnapshot: Sendable {
    public typealias State = LiveState
    public internal(set) var sources: [String: LiveState] = [:]
    public internal(set) var discardedQuestions = 0
    public internal(set) var droppedAudioChunks = 0
    public internal(set) var submittedAudioSamples: [String: Int] = [:]
    public internal(set) var recognitionSeconds: [String: Double] = [:]
    public internal(set) var recognitionTokens: [String: TokenUsage] = [:]

    public internal(set) var state: State = .idle
    public internal(set) var transcript: [InterviewTranscript] = []
    public internal(set) var answers: [InterviewAnswer] = []
    public internal(set) var levels: [String: Float] = [:]
    public internal(set) var connected: Set<String> = []
    public internal(set) var issues: [String] = []
    public internal(set) var speakers: [DiarizedSpeaker] = []
    public internal(set) var reconnects = 0
    public internal(set) var usage: TokenUsage?
}

public actor InterviewSession {
    private struct QuestionWork: Sendable {
        let event: TranscriptEvent
        let speaker: DiarizedSpeaker.ID?
        let sequence: UInt64
        let contextTurnIDs: Set<String>
        let transcriptID: String
        let holdUntil: ContinuousClock.Instant?
    }
    private var channels: [TranscriptionChannel]
    private let detector: QuestionDetector
    private let generator: any TextGenerator
    private let preferences: String
    private let interviewContext: [String]
    private let classificationBudget: ContextBudget
    private let answerBudget: ContextBudget
    private let generationTimeout: Duration
    private let classificationEvidence: @Sendable (String) async -> [String]
    private let evidence: @Sendable (String) async -> [String]
    private var captureID: UUID?
    private var cleanup: Task<Void, Never>?
    private var captureTasks: [Task<Void, Never>] = []
    private let queueLimit: Int
    private var questionQueue: AsyncStream<QuestionWork>.Continuation?
    private var questionWorker: Task<Void, Never>?
    private var classification: (work: QuestionWork, task: Task<QuestionDetector.Detection?, Error>)?
    private var ingressSequence: UInt64 = 0
    private var manualBarrier: UInt64 = 0
    private var timeline: [UUID: PipelineTiming] = [:]
    private var conversation: [ConversationTurn] = []
    private var recentCandidateAudio: [CrossSourceAttribution.Evidence] = []
    private var candidateSpeech: [CrossSourceAttribution.SpeechWindow] = []
    private var recentInterviewerAudio: [CrossSourceAttribution.Evidence] = []
    private var ambiguousAudio: Set<String> = []
    private var roleBarriers: [DiarizedSpeaker.ID: UInt64] = [:]
    private var epochs: [String: UUID] = [:]
    private var lastMeterUpdate: [String: ContinuousClock.Instant] = [:]
    private var generation: Task<Void, Never>?
    private var generationDeadline: Task<Void, Never>?
    private var activeRevision: UUID?
    private var format: AnswerFormat
    private var snapshot = InterviewSnapshot()
    private var subscriber: AsyncStream<InterviewSnapshot>.Continuation?

    public init(channels: [TranscriptionChannel], detector: QuestionDetector, generator: any TextGenerator,
                format: AnswerFormat = .brief, preferences: String = "", interviewContext: [String] = [],
                queueLimit: Int = 32, classificationBudget: ContextBudget = .init(),
                answerBudget: ContextBudget = .init(), generationTimeout: Duration = .seconds(45),
                classificationEvidence: @escaping @Sendable (String) async -> [String] = { _ in [] },
                evidence: @escaping @Sendable (String) async -> [String] = { _ in [] }) {
        self.channels = channels
        self.queueLimit = min(256, max(1, queueLimit))
        self.detector = detector
        self.generator = generator
        self.format = format
        self.preferences = preferences
        self.interviewContext = interviewContext
        self.evidence = evidence
        self.classificationBudget = classificationBudget
        self.answerBudget = answerBudget
        self.generationTimeout = generationTimeout
        self.classificationEvidence = classificationEvidence
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
        snapshot.state = channels.isEmpty ? .degraded : .connecting
        snapshot.issues.removeAll()
        snapshot.sources = Dictionary(channels.map { ($0.source.id, .connecting) }, uniquingKeysWith: { first, _ in first })
        let (work, queue) = AsyncStream<QuestionWork>.makeStream(bufferingPolicy: .bufferingOldest(queueLimit))
        questionQueue = queue
        questionWorker = Task { [weak self] in
            for await item in work {
                guard !Task.isCancelled else { return }
                await self?.classify(item, activation: id)
            }
        }
        for channel in channels {
            captureTasks.append(Task { [weak self] in
                do {
                    try await channel.run { [weak self] event in
                        await self?.receive(event, activation: id)
                    }
                    await self?.channelEnded(channel.source, activation: id, failure: nil)
                } catch {
                    await self?.channelEnded(channel.source, activation: id, failure: Task.isCancelled ? nil : publicErrorMessage(error))
                }
            })
        }
        publish()
    }

    public func pause() async {
        guard snapshot.state.isRunning || snapshot.state == .failed else { return }
        await endCapture(.paused)
    }

    public func stop() async {
        if snapshot.state == .stopped {
            await cleanup?.value
        } else {
            await endCapture(.stopped)
        }
    }

    public func replaceChannels(_ replacements: [TranscriptionChannel]) async {
        guard snapshot.state.isRunning || snapshot.state == .failed || snapshot.state == .paused else { return }
        if snapshot.state != .paused { await endCapture(.paused) }
        guard snapshot.state == .paused else { return }
        channels = replacements
        start()
    }

    public func setFormat(_ format: AnswerFormat) { self.format = format }

    public func manualQuestion(_ text: String) {
        guard captureID != nil else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        manualBarrier = ingressSequence
        generate(AcceptedQuestion(original: question, normalized: question), format: format)
    }

    public func regenerate(_ id: UUID, format: AnswerFormat? = nil) {
        guard captureID != nil,
              let answer = snapshot.answers.first(where: { $0.id == id }) else { return }
        manualBarrier = ingressSequence
        generate(answer.question, format: format ?? answer.format)
    }

    public func assignSpeaker(_ id: DiarizedSpeaker.ID, role: SourceRole) async {
        guard captureID != nil, epochs[id.sourceID] == id.epoch,
              let index = snapshot.speakers.firstIndex(where: { $0.id == id }) else { return }
        let revoked = snapshot.speakers[index].role == .interviewer && role != .interviewer
        snapshot.speakers[index].role = role
        if revoked {
            roleBarriers[id] = ingressSequence
            if classification?.work.speaker == id { classification?.task.cancel() }
            let prefix = id.epoch.uuidString + "/" + id.sourceID + "/"
            var affected = Set(snapshot.transcript.lazy.filter {
                $0.role == .interviewer && $0.speaker == id.number && $0.id.hasPrefix(prefix)
            }.map(\.id))
            for answer in snapshot.answers {
                if let origin = answer.automaticProvenance, origin.sourceID == id.sourceID,
                   origin.captureEpoch == id.epoch, origin.speaker == id.number {
                    affected.formUnion(origin.contributingTranscriptIDs)
                }
            }
            invalidateAttribution(affected, correctedRole: role)
            publish()
            await detector.revokeAttribution(affected)
        }
        await detector.assignSpeaker(id.number, role: role, sourceID: id.sourceID, epoch: id.epoch)
        updateRunningState()
        publish()
    }

    public func cancelAnswer() {
        invalidateAnswer(.cancelled)
        publish()
    }

    private func endCapture(_ state: InterviewSnapshot.State) async {
        if let cleanup {
            if state == .stopped { snapshot.state = .stopping }
            await cleanup.value
            return
        }
        captureID = nil
        epochs.removeAll()
        lastMeterUpdate.removeAll()
        roleBarriers.removeAll()
        recentCandidateAudio.removeAll()
        candidateSpeech.removeAll()
        recentInterviewerAudio.removeAll()
        ambiguousAudio.removeAll()
        let tasks = captureTasks
        captureTasks.removeAll()
        for task in tasks { task.cancel() }
        questionQueue?.finish()
        questionQueue = nil
        questionWorker?.cancel()
        classification?.task.cancel()
        let worker = questionWorker
        questionWorker = nil
        let previous = generation
        invalidateAnswer(.cancelled)
        snapshot.state = state == .paused ? .pausing : .stopping
        for id in snapshot.sources.keys { snapshot.sources[id] = snapshot.state }
        publish()
        cleanup = Task {
            await detector.invalidateAll(keepingContext: state == .paused)
            for task in tasks { await task.value }
            await worker?.value
            await previous?.value
            let final: LiveState = snapshot.state == .stopping ? .stopped : .paused
            if final == .stopped && state == .paused { await detector.invalidateAll(keepingContext: false) }
            snapshot.state = final
            for id in snapshot.sources.keys { snapshot.sources[id] = final }
            snapshot.connected.removeAll()
            snapshot.speakers.removeAll()
            snapshot.levels.removeAll()
            snapshot.transcript.removeAll { !$0.isFinal }
            publish()
            if final == .stopped {
                subscriber?.finish()
                subscriber = nil
            }
            cleanup = nil
        }
        await cleanup?.value
    }

    private func updateRunningState() {
        guard captureID != nil else { return }
        let states = Array(snapshot.sources.values)
        let questionReady = channels.contains { channel in
            guard snapshot.connected.contains(channel.source.id) else { return false }
            return channel.source.role == .interviewer || snapshot.speakers.contains {
                $0.id.sourceID == channel.source.id && $0.role == .interviewer
            }
        }
        if questionReady {
            snapshot.state = states.allSatisfy { $0 == .listening } ? .listening : .degraded
        } else if states.contains(.reconnecting) {
            snapshot.state = .reconnecting
        } else if snapshot.connected.isEmpty && states.contains(.connecting) {
            snapshot.state = .connecting
        } else if !states.isEmpty && states.allSatisfy({ $0 == .failed || $0 == .stopped }) {
            snapshot.state = states.contains(.failed) ? .failed : .degraded
        } else {
            snapshot.state = .degraded
        }
    }

    private func receive(_ event: ChannelEvent, activation: UUID) async {
        guard captureID == activation else { return }
        var revoked: Set<String> = []
        switch event {
        case .connected(let source, let epoch):
            epochs[source.id] = epoch
            snapshot.sources[source.id] = .listening
            snapshot.connected.insert(source.id)
            await detector.connect(source, epoch: epoch)
        case .gap(let source):
            epochs.removeValue(forKey: source.id)
            snapshot.sources[source.id] = .reconnecting
            snapshot.connected.remove(source.id)
            snapshot.speakers.removeAll { $0.id.sourceID == source.id }
            roleBarriers = roleBarriers.filter { $0.key.sourceID != source.id }
            snapshot.reconnects += 1
            recordIssue("Audio gap on " + source.id + ". Reconnecting.")
            invalidateSourceWork(source)
            clearAttribution(source)
            await detector.invalidate(source)
        case .sentAudio(let source, let samples):
            snapshot.submittedAudioSamples[source.id, default: 0] += samples
        case .candidateSpeech(let source, let epoch, let start, let end):
            guard epochs[source.id] == epoch, source.role == .candidate, end > start else { return }
            let now = ContinuousClock.now
            candidateSpeech.removeAll { ($0.sourceID == source.id && $0.start == start) ||
                $0.received.duration(to: now) > CrossSourceAttribution.retention }
            let window = CrossSourceAttribution.SpeechWindow(sourceID: source.id, start: start, end: end, received: now)
            candidateSpeech.append(window)
            if candidateSpeech.count > 64 { candidateSpeech.removeFirst() }
            revoked = vetoAttribution(recentInterviewerAudio.lazy.filter {
                $0.received.duration(to: now) <= CrossSourceAttribution.retention && window.makesAmbiguous($0)
            }.map(\.id))
            if revoked.isEmpty { return }
        case .dropped(_, let chunks):
            snapshot.droppedAudioChunks += chunks
        case .level(let source, let value):
            let now = ContinuousClock.now
            if let last = lastMeterUpdate[source.id], last.duration(to: now) < .milliseconds(100) { return }
            lastMeterUpdate[source.id] = now
            snapshot.levels[source.id] = value
        case .transcript(let event):
            guard epochs[event.source.id] == event.epoch else { return }
            let id = event.transcriptID
            let transcriptIndex = snapshot.transcript.firstIndex(where: { $0.id == id })
            if let transcriptIndex, snapshot.transcript[transcriptIndex].isFinal { return }
            if event.state == .final, let usage = event.recognitionUsage {
                switch usage {
                case .audioSeconds(let seconds) where seconds.isFinite && (0...86_400).contains(seconds):
                    snapshot.recognitionSeconds[event.source.id, default: 0] += seconds
                case .tokens(let tokens) where tokens.input <= 10_000_000 && tokens.output <= 10_000_000:
                    let previous = snapshot.recognitionTokens[event.source.id] ?? .init(input: 0, output: 0)
                    snapshot.recognitionTokens[event.source.id] = .init(input: previous.input + tokens.input,
                                                                       output: previous.output + tokens.output)
                default: break
                }
            }
            if event.state == .final && event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let transcriptIndex { snapshot.transcript.remove(at: transcriptIndex) }
                publish()
                return
            }
            var speakerID: DiarizedSpeaker.ID?
            var role = event.source.role
            if role == .unknown, let number = event.speaker, number >= 0, event.state == .final {
                let speaker = DiarizedSpeaker.ID(sourceID: event.source.id, epoch: event.epoch, number: number)
                speakerID = speaker
                if let known = snapshot.speakers.first(where: { $0.id == speaker }) {
                    role = known.role
                } else if snapshot.speakers.count < 32 {
                    snapshot.speakers.append(DiarizedSpeaker(id: speaker, role: .unknown))
                }
            }
            let received = ContinuousClock.now
            let hasCandidateChannel = event.source.role == .interviewer && channels.contains { $0.source.role == .candidate }
            if role == .candidate, event.source.role == .candidate {
                let evidence = CrossSourceAttribution.Evidence(event, id: id, received: received)
                recentCandidateAudio.removeAll { $0.id == id }
                recentCandidateAudio.append(evidence)
                recentCandidateAudio = Array(recentCandidateAudio.filter {
                    $0.received.duration(to: received) <= CrossSourceAttribution.retention
                }.suffix(64))
                revoked = vetoAttribution(recentInterviewerAudio.lazy.filter {
                    $0.received.duration(to: received) <= CrossSourceAttribution.retention
                        && CrossSourceAttribution.ambiguous($0, evidence)
                }.map(\.id))
            }
            if hasCandidateChannel, event.state == .final {
                let remote = CrossSourceAttribution.Evidence(event, id: id, received: received)
                recentInterviewerAudio.append(remote)
                recentInterviewerAudio = Array(recentInterviewerAudio.filter {
                    $0.received.duration(to: received) <= CrossSourceAttribution.retention
                }.suffix(64))
                ambiguousAudio.formIntersection(Set(recentInterviewerAudio.map(\.id)))
                if recentCandidateAudio.contains(where: {
                    $0.received.duration(to: received) <= CrossSourceAttribution.retention
                        && CrossSourceAttribution.ambiguous(remote, $0)
                }) {
                    role = .unknown
                    revoked = vetoAttribution([id])
                }
            }
            let item = InterviewTranscript(id: id, role: role, text: event.text, isFinal: event.state == .final,
                                           speaker: speakerID?.number)
            if let existing = transcriptIndex {
                snapshot.transcript[existing] = item
            } else {
                snapshot.transcript.append(item)
                if snapshot.transcript.count > 2_000 { snapshot.transcript.removeFirst() }
            }
            if event.state == .final, role == .interviewer {
                ingressSequence += 1
                let work = QuestionWork(event: event, speaker: speakerID, sequence: ingressSequence,
                                        contextTurnIDs: Set(classificationBudget.recent(conversation).map(\.id)), transcriptID: id,
                                        holdUntil: hasCandidateChannel ? received.advanced(by: CrossSourceAttribution.hold) : nil)
                if case .dropped = questionQueue?.yield(work) {
                    snapshot.discardedQuestions += 1
                    recordIssue("Question queue full. Transcript retained. Use the transcript to ask manually.")
                }
            }
            if event.state == .final, role != .unknown {
                conversation.append(.init(id: id, role: role, text: String(event.text.prefix(4_000))))
                if conversation.count > 64 { conversation.removeFirst() }
            }
        }
        if captureID == activation {
            updateRunningState()
            publish()
        }
        if !revoked.isEmpty { await detector.revokeAttribution(revoked) }
    }

    private func vetoAttribution(_ ids: some Sequence<String>) -> Set<String> {
        let revoked = Set(ids).subtracting(ambiguousAudio)
        ambiguousAudio.formUnion(revoked)
        invalidateAttribution(revoked, correctedRole: .unknown)
        return revoked
    }

    private func invalidateAttribution(_ transcriptIDs: Set<String>, correctedRole: SourceRole) {
        guard !transcriptIDs.isEmpty else { return }
        var questionIDs = Set(conversation.lazy.filter { transcriptIDs.contains($0.id) }.compactMap(\.questionID))
        for index in snapshot.transcript.indices where transcriptIDs.contains(snapshot.transcript[index].id) {
            snapshot.transcript[index].role = correctedRole
        }
        for index in snapshot.answers.indices {
            guard let origin = snapshot.answers[index].automaticProvenance,
                  origin.contributingTranscriptIDs.contains(where: transcriptIDs.contains) else { continue }
            let revision = snapshot.answers[index].revision
            if activeRevision == revision { invalidateAnswer(.invalidated) }
            snapshot.answers[index].state = .invalidated
            snapshot.answers[index].failure = "Interviewer attribution was withdrawn."
            questionIDs.insert(origin.questionID)
        }
        conversation.removeAll { transcriptIDs.contains($0.id) || $0.questionID.map(questionIDs.contains) == true }
        if let classification, transcriptIDs.contains(classification.work.transcriptID) { classification.task.cancel() }
    }

    private func clearAttribution(_ source: CaptureSource) {
        recentCandidateAudio.removeAll { $0.sourceID == source.id }
        candidateSpeech.removeAll { $0.sourceID == source.id }
        recentInterviewerAudio.removeAll { $0.sourceID == source.id }
    }

    private func eligible(_ work: QuestionWork, activation: UUID) -> Bool {
        guard captureID == activation, work.sequence > manualBarrier, !ambiguousAudio.contains(work.transcriptID),
              snapshot.transcript.contains(where: { $0.id == work.transcriptID && $0.role == .interviewer }),
              epochs[work.event.source.id] == work.event.epoch else { return false }
        guard let speaker = work.speaker else { return work.event.source.role == .interviewer }
        return work.sequence > (roleBarriers[speaker] ?? 0)
            && snapshot.speakers.first(where: { $0.id == speaker })?.role == .interviewer
    }

    private func classify(_ work: QuestionWork, activation: UUID) async {
        guard eligible(work, activation: activation) else { return }
        if let holdUntil = work.holdUntil, holdUntil > .now {
            do { try await Task.sleep(until: holdUntil) } catch { return }
            guard eligible(work, activation: activation) else { return }
        }
        if let remote = recentInterviewerAudio.first(where: { $0.id == work.transcriptID }),
           candidateSpeech.contains(where: { $0.received.duration(to: .now) <= CrossSourceAttribution.retention && $0.makesAmbiguous(remote) }) {
            let revoked = vetoAttribution([work.transcriptID])
            publish()
            await detector.revokeAttribution(revoked)
            return
        }
        if let ingested = work.event.timing.final, ingested.duration(to: .now) > .seconds(12) {
            snapshot.discardedQuestions += 1
            recordIssue("A question expired in the classifier queue. Use the transcript to ask manually.")
            publish()
            return
        }
        var timing = work.event.timing
        timing.classificationStarted = .now
        let context = conversation.filter { work.contextTurnIDs.contains($0.id) }
        let trustedQuestionIDs = Set(conversation.compactMap(\.questionID))
        let job = Task { [detector, classificationBudget, classificationEvidence, interviewContext] in
            let facts = await classificationEvidence(work.event.text)
            try Task.checkCancellation()
            return try await detector.detect(work.event, conversation: context,
                                             approvedEvidence: facts, interviewContext: interviewContext,
                                             budget: classificationBudget, trustedQuestionIDs: trustedQuestionIDs)
        }
        classification = (work, job)
        defer { if classification?.work.sequence == work.sequence { classification = nil } }
        do {
            if let detection = try await job.value, eligible(work, activation: activation) {
                let trusted = Set(snapshot.transcript.filter { $0.role == .interviewer }.map(\.id))
                let latestContext = conversation.filter { work.contextTurnIDs.contains($0.id) }
                guard detection.transcriptIDs.allSatisfy(trusted.contains), latestContext == context else {
                    await detector.revokeAttribution([work.transcriptID])
                    return
                }
                let question = detection.question
                timing.classificationFinished = .now
                for index in conversation.indices where detection.transcriptIDs.contains(conversation[index].id) {
                    let turn = conversation[index]
                    conversation[index] = .init(id: turn.id, role: turn.role, text: turn.text, questionID: question.id)
                }
                let origin = InterviewAnswer.AutomaticProvenance(sourceID: work.event.source.id,
                    captureEpoch: work.event.epoch, transcriptID: work.transcriptID,
                    contributingTranscriptIDs: detection.transcriptIDs, questionID: question.id, speaker: work.speaker?.number)
                generate(question, format: format, origin: .automatic(origin), timing: timing, conversation: context)
            }
        } catch where !(error is CancellationError) && eligible(work, activation: activation) {
            recordIssue("Question classification failed. Select transcript text to ask manually.")
            publish()
        } catch {}
    }

    private func invalidateSourceWork(_ source: CaptureSource) {
        if classification?.work.event.source.id == source.id { classification?.task.cancel() }
        if let activeRevision, snapshot.answers.first(where: { $0.revision == activeRevision })?
            .automaticProvenance?.sourceID == source.id { invalidateAnswer(.cancelled) }
    }

    private func channelEnded(_ source: CaptureSource, activation: UUID, failure: String?) async {
        guard captureID == activation else { return }
        if failure != nil { epochs.removeValue(forKey: source.id) }
        snapshot.sources[source.id] = failure == nil ? .stopped : .failed
        snapshot.connected.remove(source.id)
        snapshot.levels.removeValue(forKey: source.id)
        if failure == nil, source.id == "Replay" {
            recordIssue("Replay audio finished. Pending questions can finish from the retained transcript.")
        }
        if let failure {
            snapshot.speakers.removeAll { $0.id.sourceID == source.id }
            roleBarriers = roleBarriers.filter { $0.key.sourceID != source.id }
            invalidateSourceWork(source)
            clearAttribution(source)
            recordIssue(source.id + ": " + failure)
            await detector.invalidate(source)
        }
        if captureID == activation {
            updateRunningState()
            publish()
        }
    }

    private func generate(_ question: AcceptedQuestion, format: AnswerFormat, origin: InterviewAnswer.Origin = .manual,
                          timing: PipelineTiming = .init(), conversation contextOverride: [ConversationTurn]? = nil) {
        invalidateAnswer(.superseded)
        let revision = UUID()
        activeRevision = revision
        timeline[revision] = timing
        let answer = InterviewAnswer(question: question, revision: revision, format: format,
                                     text: "", state: .generating, origin: origin)
        if let index = snapshot.answers.firstIndex(where: { $0.id == question.id }) {
            snapshot.answers[index] = answer
        } else {
            snapshot.answers.append(answer)
            if snapshot.answers.count > 500 { snapshot.answers.removeFirst() }
        }
        publish()
        let began = ContinuousClock.now
        var context = answerBudget.recent(contextOverride ?? conversation).reversed().map { turn in
            let speaker = turn.role == .candidate ? "Actual candidate speech (unverified)" : "Interviewer speech"
            return speaker + ": " + turn.text
        }
        context.append(contentsOf: interviewContext)
        if let previousID = question.previousQuestionID, conversation.contains(where: { $0.questionID == previousID }),
           let prior = snapshot.answers.first(where: { $0.id == previousID && $0.state != .invalidated }) {
            context.insert("Previous interviewer question: " + prior.question.original, at: 0)
        }
        let limitedContext = answerBudget.share(70).limit(context)
        generationDeadline = Task { [weak self, generationTimeout] in
            do {
                try await Task.sleep(for: generationTimeout)
                await self?.timeout(revision)
            } catch {}
        }
        generation = Task { [weak self, generator, evidence, preferences, limitedContext, answerBudget] in
            do {
                await self?.mark(revision, \.retrievalStarted)
                let facts = answerBudget.share(30).limit(await evidence(question.normalized))
                await self?.mark(revision, \.retrievalFinished)
                try Task.checkCancellation()
                await self?.recordEvidence(facts, revision)
                let text = ([question.normalized] + question.parts).joined(separator: "\n")
                let request = AnswerRequest(question: text,
                                            instructions: format.instruction + " " + preferences,
                                            evidence: facts, interviewContext: limitedContext)
                await self?.mark(revision, \.requestStarted)
                for try await event in try await generator.stream(request) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let delta): await self?.append(delta, revision, began: began)
                    case .usage(let usage): await self?.recordUsage(usage, revision: revision)
                    }
                }
                await self?.complete(revision, state: .complete)
            } catch is CancellationError {
                await self?.complete(revision, state: .cancelled)
            } catch {
                await self?.complete(revision, state: .failed, failure: publicErrorMessage(error))
            }
        }
    }

    private func recordEvidence(_ evidence: [String], _ revision: UUID) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        snapshot.answers[index].evidence = evidence
        publish()
    }

    private func append(_ delta: String, _ revision: UUID, began: ContinuousClock.Instant) {
        guard !delta.isEmpty else { return }
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        guard snapshot.answers[index].text.utf8.count + delta.utf8.count <= 32_768 else {
            invalidateAnswer(.failed)
            publish()
            return
        }
        if snapshot.answers[index].firstTextMilliseconds == nil {
            let elapsed = began.duration(to: .now).components
            snapshot.answers[index].firstTextMilliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        }
        mark(revision, \.firstToken)
        snapshot.answers[index].text.append(delta)
        publish()
    }

    private func recordUsage(_ usage: TokenUsage, revision: UUID) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }),
              snapshot.answers[index].usage == nil else { return }
        let previous = snapshot.usage ?? TokenUsage(input: 0, output: 0)
        // Exclude malformed quantities rather than allowing a provider value to overflow a running total.
        guard usage.input <= 10_000_000, usage.output <= 10_000_000 else { return }
        snapshot.answers[index].usage = usage
        snapshot.usage = TokenUsage(input: previous.input + usage.input, output: previous.output + usage.output)
        publish()
    }

    private func complete(_ revision: UUID, state: InterviewAnswer.State, failure: String? = nil) {
        guard activeRevision == revision,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        snapshot.answers[index].state = state == .complete && snapshot.answers[index].text.isEmpty ? .failed : state
        snapshot.answers[index].failure = failure
        mark(revision, \.terminal)
        activeRevision = nil
        generation = nil
        generationDeadline?.cancel()
        generationDeadline = nil
        publish()
    }

    private func timeout(_ revision: UUID) {
        guard activeRevision == revision else { return }
        generation?.cancel()
        complete(revision, state: .failed, failure: publicErrorMessage(ProviderFailure.timeout))
    }

    private func invalidateAnswer(_ state: InterviewAnswer.State) {
        if let activeRevision, let index = snapshot.answers.firstIndex(where: { $0.revision == activeRevision }) {
            snapshot.answers[index].state = state
            mark(activeRevision, \.terminal)
        }
        activeRevision = nil
        generation?.cancel()
        generation = nil
        generationDeadline?.cancel()
        generationDeadline = nil
    }

    public func responseVisible(_ revision: UUID) {
        guard captureID != nil, timeline[revision]?.firstToken != nil,
              snapshot.answers.first(where: { $0.revision == revision && $0.state != .invalidated })?
                .text.contains(where: { !$0.isWhitespace }) == true else { return }
        mark(revision, \.firstVisible)
    }

    private func mark(_ revision: UUID, _ key: WritableKeyPath<PipelineTiming, ContinuousClock.Instant?>) {
        guard var timing = timeline[revision], timing[keyPath: key] == nil,
              let index = snapshot.answers.firstIndex(where: { $0.revision == revision }) else { return }
        timing[keyPath: key] = .now
        timeline[revision] = timing
        snapshot.answers[index].pipeline = timing.durations
        if timeline.count > 500 {
            let retained = Set(snapshot.answers.map(\.revision))
            timeline = timeline.filter { retained.contains($0.key) }
        }
        if key == \.firstVisible { publish() }
    }

    private func recordIssue(_ issue: String) {
        snapshot.issues.append(issue)
        if snapshot.issues.count > 20 { snapshot.issues.removeFirst() }
    }

    private func publish() { subscriber?.yield(snapshot) }
}
