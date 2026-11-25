import Foundation

/// Uses controlled messages because transport errors can contain headers or response bodies.
public func publicErrorMessage(_ error: Error) -> String {
    switch error {
    case ProviderFailure.missingCredentials:
        "Add the provider key in Settings."
    case ProviderFailure.authentication:
        "The provider rejected the key. Update it in Settings."
    case ProviderFailure.unsupportedCapability:
        "The selected model does not support this language, service, or processing option."
    case ProviderFailure.quotaExhausted:
        "The provider reports that the available allowance has been exhausted."
    case ProviderFailure.rateLimited:
        "The provider rate limit was reached."
    case ProviderFailure.incompleteTranscription:
        "Transcription ended with unconfirmed audio. Review the retained transcript before retrying."
    case ProviderFailure.timeout:
        "The provider timed out."
    case ProviderFailure.requestRejected, ProviderFailure.malformedEvent:
        "The provider rejected the request or returned an unsupported response. Check the configured model."
    case ProviderFailure.unavailable, ProviderFailure.disconnected:
        "The provider connection was interrupted."
    case AppleRecognitionFailure.speechPermissionDenied:
        "Allow Speech Recognition in macOS Privacy & Security, then retry."
    case AppleRecognitionFailure.unsupportedLanguage:
        "Apple Speech does not support the selected recognition language."
    case AppleRecognitionFailure.onDeviceUnavailable:
        "Strict on-device recognition is unavailable for this language on this Mac."
    case CaptureFailure.permissionDenied:
        "Allow access in macOS System Settings → Privacy & Security, then restart capture."
    case CaptureFailure.routeChanged:
        "The macOS default route or application process group changed. Reconnecting with a fresh audio stream."
    case CaptureFailure.unsupportedRoute:
        "The selected output does not expose a supported single digital stream to Core Audio taps."
    case CaptureFailure.conflictingMicrophones:
        "Choose separate devices for the interviewer and candidate microphones."
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
            "Minimum dropped audio chunks: \(droppedAudioChunks)",
            "Question queue overflows: \(discardedQuestions)",
            "Final transcript segments: \(transcript.filter(\.isFinal).count)",
            "Accepted and manual questions: \(answers.count)",
            "Completed answers: \(answers.filter { $0.state == .complete }.count)",
            usage,
            answers.last?.pipeline?.summary ?? ""
        ].joined(separator: "\n")
    }
}
