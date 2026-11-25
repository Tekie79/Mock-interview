import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol RealtimeSocket: Sendable {
    func read() async throws -> Data
    func send(_ text: String) async throws
    func close()
}

final class FoundationRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1_048_576
        task.resume()
    }

    func read() async throws -> Data {
        try await perform {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let bytes): return bytes
            @unknown default: throw ProviderFailure.malformedEvent
            }
        }
    }

    func send(_ text: String) async throws {
        try await perform { try await task.send(.string(text)) }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }

    private func perform<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await withTaskCancellationHandler(operation: body, onCancel: { self.close() })
        } catch {
            try Task.checkCancellation()
            if let response = task.response { try OpenAIResponsesClient.validate(response) }
            if let error = error as? ProviderFailure { throw error }
            if (error as? URLError)?.code == .timedOut { throw ProviderFailure.timeout }
            throw ProviderFailure.disconnected
        }
    }
}

func receiveReadiness(on socket: any RealtimeSocket, timeout: Duration = .seconds(12),
                      accepted: @escaping @Sendable (Data) throws -> Bool) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while true {
                try Task.checkCancellation()
                if try accepted(await socket.read()) { return }
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProviderFailure.timeout
        }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}
