import Foundation

public enum QuestionAudioKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case defaultOutput = "System default output"
    case outputDevice = "Specific output device"
    case application = "Application or process group"
    case interviewerMicrophone = "Dedicated interviewer microphone"
    case sharedMicrophone = "Shared microphone"
    case replay = "Recorded PCM replay"
    public var id: String { rawValue }
}

public enum QuestionAudioAttribution: String, CaseIterable, Sendable {
    case unresolved = "Mixed audio · Manual answers"
    case speakerLabels = "Mixed audio · Assign speakers"
    case interviewerOnly = "Interviewer-only audio"
}

public enum QuestionAudioMode: Equatable, Sendable {
    case trustedInterviewerOnly, separateChannels, diarized, unresolved

    public var questionRole: SourceRole {
        switch self {
        case .trustedInterviewerOnly, .separateChannels: .interviewer
        case .diarized, .unresolved: .unknown
        }
    }
}

public struct AudioEndpointChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let canTap: Bool
    public init(id: String, name: String, canTap: Bool = true) {
        self.id = id
        self.name = name
        self.canTap = canTap
    }
}

public struct AudioRoutePreference: Codable, Equatable, Sendable {
    public var question: QuestionAudioKind
    public var outputUID: String?
    public var applicationID: String?
    public var interviewerMicrophoneUID: String?
    public var candidateMicrophoneUID: String?
    public var candidateEnabled: Bool
    public var labelOutputSpeakers: Bool?
    private var trustedOutput: String?
    private var previousQuestionAudio: QuestionAudioKind?

    public init(question: QuestionAudioKind = .application, outputUID: String? = nil,
                applicationID: String? = nil, interviewerMicrophoneUID: String? = nil,
                candidateMicrophoneUID: String? = nil, candidateEnabled: Bool = false) {
        self.question = question
        self.outputUID = outputUID
        self.applicationID = applicationID
        self.interviewerMicrophoneUID = interviewerMicrophoneUID
        self.candidateMicrophoneUID = candidateMicrophoneUID
        self.candidateEnabled = candidateEnabled
    }

    public mutating func setOtherDeviceInterview(_ enabled: Bool) {
        if enabled, question != .sharedMicrophone {
            previousQuestionAudio = question
            question = .sharedMicrophone
        } else if !enabled, question == .sharedMicrophone {
            question = previousQuestionAudio ?? .application
        }
    }

    public func validateConcurrentMicrophones() throws {
        if candidateEnabled, question == .interviewerMicrophone || question == .sharedMicrophone,
           let interviewerMicrophoneUID, interviewerMicrophoneUID == candidateMicrophoneUID {
            throw CaptureFailure.conflictingMicrophones
        }
    }

    public var questionUsesOutput: Bool {
        question == .application || question == .defaultOutput || question == .outputDevice
    }

    public var requiresSpeakerLabels: Bool {
        question == .sharedMicrophone || (questionUsesOutput && labelOutputSpeakers == true)
    }

    private var outputIdentity: String? {
        switch question {
        case .defaultOutput: "default"
        case .application: applicationID.map { "application:" + $0 }
        case .outputDevice: outputUID.map { "output:" + $0 }
        default: nil
        }
    }

    public var outputAttribution: QuestionAudioAttribution {
        get {
            if labelOutputSpeakers == true { return .speakerLabels }
            if let outputIdentity, trustedOutput == outputIdentity { return .interviewerOnly }
            return .unresolved
        }
        set {
            labelOutputSpeakers = newValue == .speakerLabels
            trustedOutput = newValue == .interviewerOnly ? outputIdentity : nil
        }
    }

    public func questionMode(speakerLabelsAvailable: Bool, replayAttribution: QuestionAudioAttribution = .unresolved) -> QuestionAudioMode {
        if requiresSpeakerLabels || (question == .replay && replayAttribution == .speakerLabels) {
            return speakerLabelsAvailable ? .diarized : .unresolved
        }
        let trusted = question == .interviewerMicrophone || (question == .replay && replayAttribution == .interviewerOnly)
            || (questionUsesOutput && outputAttribution == .interviewerOnly)
        guard trusted else { return .unresolved }
        return candidateEnabled ? .separateChannels : .trustedInterviewerOnly
    }
}

public enum AudioRouteSelection {
    public static func applicationMembers(in bundleIDs: [String], group: String) -> [String] {
        bundleIDs.filter { $0 == group || $0.hasPrefix(group + ".") }
    }

    public static func output(in devices: [AudioEndpointChoice], selectedUID: String?,
                              defaultUID: String?) throws -> AudioEndpointChoice {
        guard let id = selectedUID ?? defaultUID, let device = devices.first(where: { $0.id == id }) else {
            throw CaptureFailure.sourceUnavailable
        }
        guard device.canTap else { throw CaptureFailure.unsupportedRoute }
        return device
    }
}
