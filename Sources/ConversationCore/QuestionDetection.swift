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
    private struct Channel {
        let source: CaptureSource
        let epoch: UUID
        var finalizedIDs: Set<String> = []
        var speakerRoles: [Int: SourceRole] = [:]
        var pending: (text: String, instant: ContinuousClock.Instant, speaker: Int?)?
    }

    private let classifier: any QuestionClassifier
    private let threshold: Double
    private let now: @Sendable () -> ContinuousClock.Instant
    private var channels: [String: Channel] = [:]
    private var recent: [AcceptedQuestion] = []

    public init(classifier: any QuestionClassifier, threshold: Double = 0.8,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.classifier = classifier
        self.threshold = threshold
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

    public func receive(_ event: TranscriptEvent, conversation: [ConversationTurn] = [],
                        approvedEvidence: [String] = [], interviewContext: [String] = [],
                        budget: ContextBudget = .init()) async throws -> AcceptedQuestion? {
        guard event.state == .final,
              var channel = channels[event.source.id], channel.source == event.source,
              channel.epoch == event.epoch, channel.finalizedIDs.count < 16_384,
              channel.finalizedIDs.insert(event.itemID).inserted else { return nil }
        channels[event.source.id] = channel
        guard AutomaticQuestionRoleGate.permitsClassification(for: Self.role(of: event, channel: channel)) else {
            channels[event.source.id]?.pending = nil
            return nil
        }

        let arrived = now()
        var text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .punctuationCharacters)
        if text.isEmpty || Self.obviousNonQuestions.contains(folded) {
            channels[event.source.id] = channel
            return nil
        }
        if let pending = channel.pending, pending.speaker == event.speaker,
           pending.instant.duration(to: arrived) <= .seconds(3) {
            text = pending.text.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")) + " " + text
        }
        channel.pending = nil
        channels[event.source.id] = channel
        guard text.utf8.count <= 16_000 else { return nil }
        if text.hasSuffix("...") || text.hasSuffix("…") {
            channels[event.source.id]?.pending = (text, arrived, event.speaker)
            return nil
        }

        let turn = TranscriptEvent(source: event.source, epoch: event.epoch, itemID: event.itemID,
                                   previousItemID: event.previousItemID, text: text, state: .final, speaker: event.speaker)
        let context = recent
        let result = try await classifier.classify(QuestionInput(
            turn: turn,
            previousQuestions: budget.limit(context.suffix(4).reversed().map { "\($0.id.uuidString): \($0.normalized)" }),
            conversation: budget.recent(conversation),
            approvedEvidence: budget.limit(approvedEvidence),
            interviewContext: budget.limit(interviewContext)))
        try Task.checkCancellation()
        guard let active = channels[event.source.id], active.epoch == event.epoch,
              AutomaticQuestionRoleGate.permitsClassification(for: Self.role(of: event, channel: active)),
              arrived.duration(to: now()) <= .seconds(12) else { return nil }

        if result.decision == .wait {
            channels[event.source.id]?.pending = (text, arrived, event.speaker)
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
        let question = AcceptedQuestion(original: text, normalized: normalized, parts: result.parts,
                                        previousQuestionID: result.isFollowUp || result.isIntentionalRepeat
                                            ? matched ?? context.last?.id : nil)
        recent.append(question)
        if recent.count > 8 { recent.removeFirst() }
        return question
    }

    private static func role(of event: TranscriptEvent, channel: Channel) -> SourceRole {
        guard event.source.role == .unknown, let speaker = event.speaker else { return event.source.role }
        return channel.speakerRoles[speaker] ?? .unknown
    }

    private static let obviousNonQuestions: Set<String> = [
        "hi", "hello", "thanks", "thank you", "can you hear me", "can you see my screen",
        "can you see me", "are you muted", "that's a good answer. thank you", "do you know what i mean"
    ]
}
