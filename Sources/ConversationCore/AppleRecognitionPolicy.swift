import Foundation

public enum AppleRecognitionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice = "Strictly on device"
    case networkPermitted = "Network permitted"
    public var id: String { rawValue }
}

public enum AppleRecognitionFailure: Error, Equatable, Sendable {
    case unsupportedLanguage
    case onDeviceUnavailable
    case speechPermissionDenied
}

public enum AppleRecognitionPolicy {
    public static func validate(language: String, supported: Set<String>, mode: AppleRecognitionMode,
                                onDeviceAvailable: Bool) throws {
        guard supported.map(canonicalLanguage).contains(canonicalLanguage(language)) else {
            throw AppleRecognitionFailure.unsupportedLanguage
        }
        if mode == .onDevice && !onDeviceAvailable {
            throw AppleRecognitionFailure.onDeviceUnavailable
        }
    }

    private static func canonicalLanguage(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
