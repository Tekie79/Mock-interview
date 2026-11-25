import Dispatch

/// Serializes OS credential operations off the UI thread and reuses approved reads for this launch.
public final class ProviderCredentialStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mockinterview.provider-credentials", qos: .userInitiated)
    private let read: @Sendable (String) -> String?
    private let persist: @Sendable (String, String) throws -> Void
    // Access only on queue, including during save and removal.
    private var credentials: [String: String] = [:]

    public init(read: @escaping @Sendable (String) -> String?,
                persist: @escaping @Sendable (String, String) throws -> Void) {
        self.read = read
        self.persist = persist
    }

    public func load(_ account: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let credential = credentials[account] {
                    continuation.resume(returning: credential)
                    return
                }
                let credential = read(account).flatMap { $0.isEmpty ? nil : $0 }
                credentials[account] = credential
                continuation.resume(returning: credential)
            }
        }
    }

    public func save(_ value: String, account: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try persist(value, account)
                    credentials[account] = value.isEmpty ? nil : value
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
