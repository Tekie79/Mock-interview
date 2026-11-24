/// Explicitly resolved role of the captured audio source or speaker.
public enum SourceRole: String, Codable, Sendable, CaseIterable {
    case interviewer
    case candidate
    case unknown
}

/// Minimal invariant for the automatic path. This is NOT a question classifier.
/// A permitted interviewer turn must still pass completion, relevance, freshness,
/// deduplication, and cancellation checks before generating any answer.
public enum AutomaticQuestionRoleGate {
    public static func permitsClassification(for role: SourceRole) -> Bool {
        role == .interviewer
    }
}
