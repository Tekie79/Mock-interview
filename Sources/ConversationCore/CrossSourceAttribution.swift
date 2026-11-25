import Foundation

/// Transcript correlation is an attribution veto, not acoustic echo cancellation or speaker recognition.
struct CrossSourceAttribution {
    static let hold: Duration = .milliseconds(350)
    static let retention: Duration = .seconds(12)

    struct Evidence {
        let sourceID: String
        let id: String
        let received: ContinuousClock.Instant
        let start: ContinuousClock.Instant?
        let end: ContinuousClock.Instant?
        let tokens: [Substring]

        init(_ event: TranscriptEvent, id: String, received: ContinuousClock.Instant = .now) {
            sourceID = event.source.id
            self.id = id
            self.received = received
            start = event.timing.speechStart
            end = event.timing.endpoint
            tokens = Array(event.text.prefix(512).lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(64))
        }
    }

    struct SpeechWindow {
        let sourceID: String
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
        let received: ContinuousClock.Instant

        func makesAmbiguous(_ remote: Evidence) -> Bool {
            guard let remoteStart = remote.start, let remoteEnd = remote.end, remoteEnd > remoteStart,
                  remote.sourceID != sourceID, Self.overlap(start, end, remoteStart, remoteEnd) >= remoteStart.duration(to: remoteEnd) * 3 / 4 else { return false }
            // Only a near-matching envelope is enough without text; a longer candidate utterance can overlap by coincidence.
            return CrossSourceAttribution.close(start, remoteStart, within: .milliseconds(180))
                && CrossSourceAttribution.close(end, remoteEnd, within: .milliseconds(240))
        }

        private static func overlap(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant,
                                    _ otherStart: ContinuousClock.Instant, _ otherEnd: ContinuousClock.Instant) -> Duration {
            max(start, otherStart).duration(to: min(end, otherEnd))
        }
    }

    static func ambiguous(_ remote: Evidence, _ candidate: Evidence) -> Bool {
        guard remote.sourceID != candidate.sourceID, !remote.tokens.isEmpty, !candidate.tokens.isEmpty else { return false }
        if let start = remote.start, let end = remote.end, end > start,
           let candidateStart = candidate.start, let candidateEnd = candidate.end, candidateEnd > candidateStart {
            // Require contemporaneous audio, not contemporaneous callback delivery.
            let overlap = max(start, candidateStart).duration(to: min(end, candidateEnd))
            guard overlap > .zero else { return false }
            let shorter = min(start.duration(to: end), candidateStart.duration(to: candidateEnd))
            guard overlap >= shorter / 2 else { return false }
            if remote.tokens == candidate.tokens { return true }
            let tightStart = close(start, candidateStart, within: .milliseconds(160))
            let tightEnd = close(end, candidateEnd, within: .milliseconds(180))
            if tightStart && tightEnd { return true }
            return similar(remote.tokens, candidate.tokens)
        }
        // Arrival-only evidence must be temporally close and textually stronger than overlap evidence.
        guard close(remote.received, candidate.received, within: .seconds(2)) else { return false }
        return remote.tokens == candidate.tokens || similar(remote.tokens, candidate.tokens)
    }

    private static func close(_ first: ContinuousClock.Instant, _ second: ContinuousClock.Instant,
                              within duration: Duration) -> Bool {
        min(first, second).duration(to: max(first, second)) <= duration
    }

    private static func similar(_ first: [Substring], _ second: [Substring]) -> Bool {
        let left = Set(first), right = Set(second)
        let shared = left.intersection(right).count
        // Keep short, distinct follow-ups out of the fuzzy path.
        return shared >= 2 && shared * 3 >= left.union(right).count * 2
            && max(first.count, second.count) <= min(first.count, second.count) + 3
    }
}
