import Foundation

public struct AcceptedQuestion: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let original: String
    public let normalized: String
    public let parts: [String]
    public let previousQuestionID: UUID?

    public init(id: UUID = UUID(), original: String, normalized: String, parts: [String] = [],
                previousQuestionID: UUID? = nil) {
        self.id = id
        self.original = original
        self.normalized = normalized
        self.parts = parts
        self.previousQuestionID = previousQuestionID
    }
}

public actor QuestionDetector {
    struct Detection: Sendable {
        let question: AcceptedQuestion
        let transcriptIDs: [String]
    }

    private struct Channel {
        let source: CaptureSource
        let epoch: UUID
        var finalizedIDs: Set<String> = []
        var speakerRoles: [Int: SourceRole] = [:]
        var pending: (text: String, instant: ContinuousClock.Instant, speaker: Int?, transcriptIDs: [String])?
    }

    private let classifier: any QuestionClassifier
    private let threshold: Double
    private let completionGrace: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var channels: [String: Channel] = [:]
    private var recent: [Detection] = []
    private var inFlight: [UUID: Set<String>] = [:]

    public init(classifier: any QuestionClassifier, threshold: Double = 0.8,
                completionGrace: Duration = .seconds(3), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.classifier = classifier
        self.threshold = min(1, max(0, threshold))
        self.completionGrace = completionGrace
        self.now = now
    }

    public func connect(_ source: CaptureSource, epoch: UUID) {
        if channels[source.id]?.epoch != epoch {
            channels[source.id] = Channel(source: source, epoch: epoch)
        }
    }

    public func assignSpeaker(_ speaker: Int, role: SourceRole, sourceID: String, epoch: UUID) {
        guard speaker >= 0, let channel = channels[sourceID], channel.source.role == .unknown,
              channel.epoch == epoch, channel.speakerRoles.count < 32 || channel.speakerRoles[speaker] != nil else {
            return
        }
        channels[sourceID]?.speakerRoles[speaker] = role
        channels[sourceID]?.pending = nil
    }

    public func invalidate(_ source: CaptureSource) {
        channels.removeValue(forKey: source.id)
    }

    public func invalidateAll(keepingContext: Bool) {
        channels.removeAll()
        if !keepingContext { recent.removeAll() }
    }

    func revokeAttribution(_ transcriptIDs: Set<String>) {
        guard !transcriptIDs.isEmpty else { return }
        inFlight = inFlight.filter { $0.value.isDisjoint(with: transcriptIDs) }
        recent.removeAll { $0.transcriptIDs.contains(where: transcriptIDs.contains) }
        for id in Array(channels.keys) {
            if channels[id]?.pending?.transcriptIDs.contains(where: transcriptIDs.contains) == true {
                channels[id]?.pending = nil
            }
        }
    }

    public func receive(_ event: TranscriptEvent, conversation: [ConversationTurn] = [],
                        approvedEvidence: [String] = [], interviewContext: [String] = [],
                        budget: ContextBudget = .init()) async throws -> AcceptedQuestion? {
        try await detect([event], conversation: conversation, approvedEvidence: approvedEvidence,
                         interviewContext: interviewContext, budget: budget)?.question
    }

    func detect(_ segments: [TranscriptEvent], conversation: [ConversationTurn], approvedEvidence: [String],
                interviewContext: [String], budget: ContextBudget, trustedQuestionIDs: Set<UUID>? = nil) async throws -> Detection? {
        guard let event = segments.last, segments.count <= 64,
              var channel = channels[event.source.id], channel.source == event.source,
              channel.epoch == event.epoch, channel.finalizedIDs.count + segments.count <= 16_384,
              segments.allSatisfy({ $0.state == .final && $0.source == event.source && $0.epoch == event.epoch
                  && $0.speaker == event.speaker }) else { return nil }
        let itemIDs = Set(segments.map(\.itemID))
        guard itemIDs.count == segments.count, channel.finalizedIDs.isDisjoint(with: itemIDs) else { return nil }
        channel.finalizedIDs.formUnion(itemIDs)
        channels[event.source.id] = channel
        guard AutomaticQuestionRoleGate.permitsClassification(for: Self.role(of: event, channel: channel)) else {
            channels[event.source.id]?.pending = nil
            return nil
        }

        let arrived = now()
        let substantiveSegments = segments.filter { !Self.isObviousNonQuestion($0.text) }
        var transcriptIDs = substantiveSegments.map(\.transcriptID)
        var text = substantiveSegments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        if text.isEmpty {
            channels[event.source.id] = channel
            return nil
        }
        if let pending = channel.pending, pending.speaker == event.speaker,
           pending.instant.duration(to: arrived) <= completionGrace {
            text = pending.text.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")) + " " + text
            transcriptIDs = pending.transcriptIDs + transcriptIDs
        }
        channel.pending = nil
        channels[event.source.id] = channel
        guard text.utf8.count <= 16_000, transcriptIDs.count <= 64 else { return nil }
        let lastWord = text.lowercased().split(whereSeparator: { !$0.isLetter }).last
        if text.hasSuffix("...") || text.hasSuffix("…") || ["and", "or", "then", "because"].contains(lastWord.map(String.init) ?? "") {
            channels[event.source.id]?.pending = (text, arrived, event.speaker, transcriptIDs)
            return nil
        }

        let turn = TranscriptEvent(source: event.source, epoch: event.epoch, itemID: event.itemID,
                                   previousItemID: event.previousItemID, text: text, state: .final, speaker: event.speaker,
                                   turnProbability: event.turnProbability)
        let history = recent.filter { trustedQuestionIDs?.contains($0.question.id) != false }
        let context = history.map(\.question)
        let request = UUID()
        inFlight[request] = Set(transcriptIDs + conversation.map(\.id) + history.flatMap(\.transcriptIDs))
        defer { inFlight.removeValue(forKey: request) }
        let result = try await classifier.classify(QuestionInput(
            turn: turn,
            previousQuestions: budget.share(15).limit(context.suffix(4).reversed().map { "\($0.id.uuidString): \($0.normalized)" }),
            conversation: budget.share(55).recent(conversation),
            approvedEvidence: budget.share(15).limit(approvedEvidence),
            interviewContext: budget.share(15).limit(interviewContext)))
        try Task.checkCancellation()
        guard inFlight[request] != nil, let active = channels[event.source.id], active.epoch == event.epoch,
              AutomaticQuestionRoleGate.permitsClassification(for: Self.role(of: event, channel: active)),
              arrived.duration(to: now()) <= .seconds(12) else { return nil }

        if result.decision == .wait {
            channels[event.source.id]?.pending = (text, arrived, event.speaker, transcriptIDs)
            return nil
        }
        let normalized = result.normalizedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.decision == .accept, (threshold...1).contains(result.confidence),
              !normalized.isEmpty, normalized.utf8.count <= 16_000, !result.parts.isEmpty,
              result.parts.count <= 12, result.parts.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_000
              }) else { return nil }
        let references = Set(result.contextTurnIDs)
        let matched = context.last(where: { references.contains($0.id.uuidString) })?.id
            ?? conversation.last(where: { references.contains($0.id) && $0.questionID != nil })?.questionID
        let canLinkLiteralRepeat = result.isIntentionalRepeat || !result.isFollowUp
        let priorRepeat = canLinkLiteralRepeat ? context.last(where: {
            $0.original.caseInsensitiveCompare(text) == .orderedSame
        })?.id : nil
        let contextualReference = result.isFollowUp || result.isIntentionalRepeat ? matched ?? context.last?.id : nil
        let question = AcceptedQuestion(original: text, normalized: normalized, parts: result.parts,
                                        previousQuestionID: priorRepeat ?? contextualReference)
        let detection = Detection(question: question, transcriptIDs: transcriptIDs)
        recent.append(detection)
        if recent.count > 8 { recent.removeFirst() }
        return detection
    }

    private static func role(of event: TranscriptEvent, channel: Channel) -> SourceRole {
        guard event.source.role == .unknown, let speaker = event.speaker else { return event.source.role }
        return channel.speakerRoles[speaker] ?? .unknown
    }

    private static let obviousNonQuestions: Set<String> = [
        "hi", "hello", "thanks", "thank you", "can you hear me", "can you see my screen",
        "can you see me", "can you see the next slide", "is the screen readable", "are you muted",
        "that's a good answer. thank you", "do you know what i mean"
    ]

    private static func isOnlyCallLogistics(_ text: String) -> Bool {
        let sentences = text.split(whereSeparator: { ".!?".contains($0) })
        return sentences.count > 1 && sentences.allSatisfy {
            obviousNonQuestions.contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func isObviousNonQuestion(_ text: String) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .punctuationCharacters)
        return folded.isEmpty || obviousNonQuestions.contains(folded) || isOnlyCallLogistics(folded)
    }
}
