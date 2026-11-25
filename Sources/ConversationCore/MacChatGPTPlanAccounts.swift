#if os(macOS)
import AppKit
import Foundation
import Security

extension ChatGPTPlanAccounts {
    public static func makeDesktop() -> ChatGPTPlanAccounts? {
        guard ChatGPTPlanEligibility.desktopAvailable else { return nil }
        return ChatGPTPlanAccounts(
            browser: .init(listen: { try await MacChatGPTLoopback.start() }, open: { NSWorkspace.shared.open($0) },
                secrets: { try MacChatGPTPlanSecurity.secrets() }),
            transport: .init(data: { try await MacChatGPTPlanHTTP.data($0) },
                stream: { MacChatGPTPlanHTTP.stream($0) }, signature: { kid, payload, signature in
                    try await MacChatGPTPlanSecurity.Keys.download().verify(kid, payload, signature)
                }),
            store: .init(load: { try MacPlanKeychain.load() }, save: { try MacPlanKeychain.save($0) }))
    }
}

enum MacChatGPTPlanHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.timeoutIntervalForResource = 45
        return URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.disconnected }
        return (try await read(bytes, limit: 1_048_576), http)
    }

    static func stream(_ request: URLRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, output) = AsyncThrowingStream<GenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw ProviderFailure.disconnected }
                if !(200...299).contains(http.statusCode) {
                    try ChatGPTSubscriptionProvider.validate(http, body: try await read(bytes, limit: 16_384))
                }
                guard http.mimeType == "text/event-stream" else { throw ProviderFailure.malformedEvent }
                var parser = ChatGPTSubscriptionProvider.ResponseStream()
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if byte == 10 || chunk.count == 4_096 {
                        try parser.receive(chunk) { event in
                            if case .dropped = output.yield(event) { throw CaptureFailure.bufferOverrun }
                        }
                        if parser.completed { break }
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                try parser.finish()
                output.finish()
            } catch let error as URLError {
                output.finish(throwing: Task.isCancelled ? CancellationError() :
                    (error.code == .timedOut ? ProviderFailure.timeout : ProviderFailure.disconnected))
            } catch { output.finish(throwing: error) }
        }
        output.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func read(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else { throw ProviderFailure.malformedEvent }
            body.append(byte)
        }
        return body
    }
}

private enum MacPlanKeychain {
    private static let query: [String: String] = [kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.mockinterview.desktop.chatgpt-plan", kSecAttrAccount as String: "account-vault.v1"]

    static func load() throws -> ChatGPTPlanAccounts.Vault? {
        var request: [String: Any] = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw PlanAuthorizationFailure.storageUnavailable }
        return try JSONDecoder().decode(ChatGPTPlanAccounts.Vault.self, from: bytes)
    }

    static func save(_ value: ChatGPTPlanAccounts.Vault) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item: [String: Any] = query
            item.merge(attributes) { _, latest in latest }
            item[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PlanAuthorizationFailure.storageUnavailable }
    }
}
#endif
