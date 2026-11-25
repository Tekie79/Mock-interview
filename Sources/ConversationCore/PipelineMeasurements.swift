import Foundation

public struct PipelineTiming: Equatable, Sendable {
    public var capture: ContinuousClock.Instant?
    public var speechStart: ContinuousClock.Instant?
    public var endpoint: ContinuousClock.Instant?
    public var commit: ContinuousClock.Instant?
    public var firstPartial: ContinuousClock.Instant?
    public var final: ContinuousClock.Instant?
    public var classificationStarted: ContinuousClock.Instant?
    public var classificationFinished: ContinuousClock.Instant?
    public var retrievalStarted: ContinuousClock.Instant?
    public var retrievalFinished: ContinuousClock.Instant?
    public var requestStarted: ContinuousClock.Instant?
    public var firstToken: ContinuousClock.Instant?
    public var firstVisible: ContinuousClock.Instant?
    public var terminal: ContinuousClock.Instant?
    public init() {}

    public var durations: PipelineDurations {
        .init(captureToSpeech: Self.measure(capture, speechStart),
              speech: Self.measure(speechStart, endpoint),
              endpointToCommit: Self.measure(endpoint, commit),
              speechToPartial: Self.measure(speechStart, firstPartial),
              commitToFinal: Self.measure(commit, final),
              classificationQueue: Self.measure(final, classificationStarted),
              classification: Self.measure(classificationStarted, classificationFinished),
              retrieval: Self.measure(retrievalStarted, retrievalFinished),
              requestToToken: Self.measure(requestStarted, firstToken),
              endpointToVisible: Self.measure(endpoint, firstVisible),
              endpointToTerminal: Self.measure(endpoint, terminal))
    }

    private static func measure(_ start: ContinuousClock.Instant?, _ end: ContinuousClock.Instant?) -> Int? {
        guard let start, let end, end >= start else { return nil }
        let elapsed = start.duration(to: end).components
        return Int(clamping: elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

public struct PipelineDurations: Codable, Equatable, Sendable {
    public let captureToSpeech: Int?
    public let speech: Int?
    public let endpointToCommit: Int?
    public let speechToPartial: Int?
    public let commitToFinal: Int?
    public let classificationQueue: Int?
    public let classification: Int?
    public let retrieval: Int?
    public let requestToToken: Int?
    public let endpointToVisible: Int?
    public let endpointToTerminal: Int?

    public var summary: String {
        [("Capture to speech", captureToSpeech), ("Speech", speech), ("Endpoint to commit", endpointToCommit),
         ("Speech to partial", speechToPartial), ("Commit to final", commitToFinal),
         ("Classifier queue", classificationQueue), ("Classification", classification), ("Retrieval", retrieval),
         ("Request to token", requestToToken), ("Endpoint to visible", endpointToVisible),
         ("Endpoint to terminal", endpointToTerminal)].compactMap { label, value in
            value.map { "\(label): \($0) ms" }
        }.joined(separator: "\n")
    }
}
