import Foundation

/// Uses controlled messages because transport errors can contain headers or response bodies.
public func publicErrorMessage(_ error: Error) -> String {
    switch error {
    case ProviderFailure.missingCredentials:
        "Add the provider key in Settings."
    case ProviderFailure.authentication:
        "The provider rejected the key. Update it in Settings."
    case ProviderFailure.rateLimited:
        "The provider rate limit was reached."
    case ProviderFailure.timeout:
        "The provider timed out."
    case ProviderFailure.requestRejected, ProviderFailure.malformedEvent:
        "The provider rejected the request or returned an unsupported response. Check the configured model."
    case ProviderFailure.unavailable, ProviderFailure.disconnected:
        "The provider connection was interrupted."
    case CaptureFailure.permissionDenied:
        "Allow access in macOS System Settings → Privacy & Security, then restart capture."
    case CaptureFailure.sourceUnavailable:
        "The selected source changed or stopped. Stop the session and reselect the source."
    case CaptureFailure.bufferOverrun:
        "The input queue filled and audio was dropped."
    case CaptureFailure.invalidFormat:
        "The selected audio format is unsupported."
    case CaptureFailure.hardware:
        "macOS could not start the selected source. Check its permissions and availability."
    default:
        "An operation failed. Retry or check the source and provider settings."
    }
}

public extension InterviewSnapshot {
    /// This export deliberately uses only counters and typed states.
    var diagnosticSummary: String {
        let usage = usage.map { "Answer tokens: \($0.input) input, \($0.output) output" }
            ?? "Answer tokens: unavailable"
        return [
            "Mock Interview",
            "Session state: \(state.rawValue)",
            "Connected source count: \(connected.count)",
            "STT reconnects: \(reconnects)",
            "Final transcript segments: \(transcript.filter(\.isFinal).count)",
            "Accepted and manual questions: \(answers.count)",
            "Completed answers: \(answers.filter { $0.state == .complete }.count)",
            usage
        ].joined(separator: "\n")
    }
}
