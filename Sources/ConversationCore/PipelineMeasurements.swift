import Foundation

public enum AudioTimingBasis: String, Codable, Sendable {
    case localSpeechEstimate = "Local speech estimate"
    case providerRangeEstimate = "Provider range mapped to capture clock"
}

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
    public var audioTimingBasis: AudioTimingBasis?
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
              endpointToTerminal: Self.measure(endpoint, terminal), audioTimingBasis: audioTimingBasis)
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
    public let audioTimingBasis: AudioTimingBasis?

    public var summary: String {
        let values = [("Capture to speech", captureToSpeech), ("Speech", speech), ("Endpoint to commit", endpointToCommit),
         ("Speech to partial", speechToPartial), ("Commit to final", commitToFinal),
         ("Classifier queue", classificationQueue), ("Classification", classification), ("Retrieval", retrieval),
         ("Request to token", requestToToken), ("Endpoint to visible", endpointToVisible),
         ("Endpoint to terminal", endpointToTerminal)].compactMap { label, value in
            value.map { "\(label): \($0) ms" }
         }
        return (["Audio timing: \(audioTimingBasis?.rawValue ?? "Unavailable")"] + values).joined(separator: "\n")
    }
}


/// Maps provider-relative audio positions onto the sample clock of an activation.
/// Retains about three minutes at nominal frame cadence without storing audio.
struct StreamAudioClock {
    private struct Anchor {
        let sample: Int64
        let instant: ContinuousClock.Instant
    }

    private let capacity = 2_048
    private var anchors: [Anchor] = []
    private var head = 0
    private var sampleOrigin: Int64?
    private var latestSample: Int64 = 0

    mutating func record(_ frame: AudioFrame) {
        if sampleOrigin == nil { sampleOrigin = frame.startSample }
        let sample = frame.startSample - (sampleOrigin ?? frame.startSample)
        latestSample = sample + Int64(frame.pcm.count / 2)
        if let last = lastAnchor, sample - last.sample < 2_400 { return }
        let anchor = Anchor(sample: sample, instant: frame.capturedAt)
        if anchors.count < capacity { anchors.append(anchor) }
        else {
            anchors[head] = anchor
            head = (head + 1) % capacity
        }
    }

    func measure(_ range: TranscriptAudioRange) -> (start: ContinuousClock.Instant, end: ContinuousClock.Instant)? {
        guard range.startSeconds.isFinite, range.endSeconds.isFinite,
              range.startSeconds >= 0, range.endSeconds > range.startSeconds,
              range.endSeconds <= Double(latestSample) / 24_000 else { return nil }
        guard let start = Int64(exactly: (range.startSeconds * 24_000).rounded(.towardZero)),
              let end = Int64(exactly: (range.endSeconds * 24_000).rounded(.towardZero)),
              let first = lookup(start), let last = lookup(end), last >= first else { return nil }
        return (first, last)
    }

    private var lastAnchor: Anchor? {
        guard !anchors.isEmpty else { return nil }
        return anchors[(head + anchors.count - 1) % anchors.count]
    }

    private func lookup(_ target: Int64) -> ContinuousClock.Instant? {
        var low = 0
        var high = anchors.count
        while low < high {
            let middle = (low + high) / 2
            if anchors[(head + middle) % anchors.count].sample <= target { low = middle + 1 }
            else { high = middle }
        }
        guard low > 0 else { return nil }
        let anchor = anchors[(head + low - 1) % anchors.count]
        let samples = target - anchor.sample
        let elapsed = Duration.seconds(samples / 24_000) + .nanoseconds(samples % 24_000 * 1_000_000_000 / 24_000)
        return anchor.instant.advanced(by: elapsed)
    }
}
