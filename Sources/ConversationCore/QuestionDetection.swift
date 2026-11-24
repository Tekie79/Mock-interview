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
        var pending: (text: String, instant: ContinuousClock.Instant)?
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

    public func invalidate(_ source: CaptureSource) {
        channels.removeValue(forKey: source.id)
    }

    public func invalidateAll(keepingContext: Bool) {
        channels.removeAll()
        if !keepingContext { recent.removeAll() }
    }

    public func receive(_ event: TranscriptEvent) async throws -> AcceptedQuestion? {
        guard event.state == .final,
              AutomaticQuestionRoleGate.permitsClassification(for: event.source.role),
              var channel = channels[event.source.id], channel.source == event.source,
              channel.epoch == event.epoch, channel.finalizedIDs.count < 16_384,
              channel.finalizedIDs.insert(event.itemID).inserted else { return nil }

        let arrived = now()
        var text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .punctuationCharacters)
        if text.isEmpty || Self.obviousNonQuestions.contains(folded) {
            channels[event.source.id] = channel
            return nil
        }
        if let pending = channel.pending, pending.instant.duration(to: arrived) <= .seconds(3) {
            text = pending.text.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")) + " " + text
        }
        channel.pending = nil
        channels[event.source.id] = channel
        guard text.utf8.count <= 16_000 else { return nil }

        let turn = TranscriptEvent(source: event.source, epoch: event.epoch, itemID: event.itemID,
                                   previousItemID: event.previousItemID, text: text, state: .final)
        let context = recent
        let result = try await classifier.classify(QuestionInput(
            turn: turn, previousQuestions: context.map(\.normalized)))
        try Task.checkCancellation()
        guard channels[event.source.id]?.epoch == event.epoch,
              arrived.duration(to: now()) <= .seconds(12) else { return nil }

        if result.decision == .wait {
            channels[event.source.id]?.pending = (text, arrived)
            return nil
        }
        let normalized = result.normalizedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.decision == .accept, (threshold...1).contains(result.confidence),
              !normalized.isEmpty, !result.parts.isEmpty, result.parts.count <= 12 else { return nil }
        let question = AcceptedQuestion(original: text, normalized: normalized, parts: result.parts,
                                        previousQuestionID: result.isFollowUp || result.isIntentionalRepeat
                                            ? context.last?.id : nil)
        recent.append(question)
        if recent.count > 8 { recent.removeFirst() }
        return question
    }

    private static let obviousNonQuestions: Set<String> = [
        "hi", "hello", "thanks", "thank you", "can you hear me", "can you see my screen",
        "can you see me", "are you muted", "that's a good answer. thank you", "do you know what i mean"
    ]
}
