import Foundation

/// Uses controlled messages because transport errors can contain headers or response bodies.
public func publicErrorMessage(_ error: Error) -> String {
    switch error {
    case TranscriptionRecoveryFailure.exhausted(let failure):
        "Transcription recovery attempts exhausted. " + publicErrorMessage(failure)
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
    case CaptureFailure.hardwareStartupTimedOut:
        "Audio startup timed out waiting for macOS. Check Privacy & Security and retry once the device is available."
    case CaptureFailure.hardwareStartupBusy:
        "macOS is still releasing an earlier audio setup. Retry when the device is available."
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
        let recognitionTime = recognitionSeconds.isEmpty ? "unavailable" :
            recognitionSeconds.values.reduce(0, +).formatted(.number.precision(.fractionLength(0...2)))
        let recognitionUsage = recognitionTokens.isEmpty ? "unavailable" :
            "\(recognitionTokens.values.reduce(0) { $0 + $1.input }) input, \(recognitionTokens.values.reduce(0) { $0 + $1.output }) output"
        return [
            "Mock Interview",
            "Session state: \(state.rawValue)",
            "Connected source count: \(connected.count)",
            "STT reconnects: \(reconnects)",
            "PCM seconds submitted locally: \(submittedAudioSamples.values.reduce(0, +) / 24_000)",
            "Provider-reported recognition seconds: \(recognitionTime)",
            "Provider-reported recognition tokens: \(recognitionUsage)",
            "Minimum dropped audio chunks: \(droppedAudioChunks)",
            "Discarded questions: \(discardedQuestions)",
            "Peak pending classifier batches: \(questionQueuePeak)",
            "Question decisions: " + questionDispositions.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", "),
            "Final transcript segments: \(transcript.filter(\.isFinal).count)",
            "Accepted and manual questions: \(answers.count)",
            "Completed answers: \(answers.filter { $0.state == .complete }.count)",
            "Session summaries completed: \(sessionSummariesCompleted), failed: \(sessionSummariesFailed)",
            usage,
            answers.last?.pipeline?.summary ?? ""
        ].joined(separator: "\n")
    }
}
