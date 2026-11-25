#if os(macOS)
import Foundation
import Network

/// Mutable listener and connection state is confined to one dispatch queue.
final class MacChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mockinterview.chatgpt-loopback")
    private let listener: NWListener
    private let ready = AsyncThrowingStream<URL, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let callbacks = AsyncThrowingStream<URL, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
    private var connections: [UUID: NWConnection] = [:]
    private var redirect: URL?
    private var stopped = false

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> ChatGPTPlanAccounts.Listener {
        let server: MacChatGPTLoopback
        do { server = try MacChatGPTLoopback() }
        catch { throw PlanAuthorizationFailure.callbackUnavailable }
        return try await withTaskCancellationHandler {
            server.begin()
            do {
                var iterator = server.ready.stream.makeAsyncIterator()
                guard let redirect = try await iterator.next() else { throw PlanAuthorizationFailure.callbackUnavailable }
                try Task.checkCancellation()
                return .init(redirect: redirect, callbacks: server.callbacks.stream, close: { server.close() })
            } catch {
                server.close()
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { server.close() }
    }

    private func begin() {
        queue.async {
            guard !self.stopped else { return }
            self.listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port, port.rawValue > 0,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else {
                        self.stop(PlanAuthorizationFailure.callbackUnavailable)
                        return
                    }
                    self.redirect = url
                    self.ready.continuation.yield(url)
                    self.ready.continuation.finish()
                case .failed, .cancelled: self.stop(PlanAuthorizationFailure.callbackUnavailable)
                default: break
                }
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let self, self.redirect == nil { self.stop(PlanAuthorizationFailure.callbackUnavailable) }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, let redirect, connections.count < 8,
              case .hostPort(let host, _) = connection.endpoint, host == NWEndpoint.Host("127.0.0.1") else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(id, redirect: redirect, prefix: Data())
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.cancel(id) }
    }

    private func receive(_ id: UUID, redirect: URL, prefix: Data) {
        let limit = 16_384
        guard let connection = connections[id], prefix.count < limit else { cancel(id); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - prefix.count) { [weak self] data, _, eof, error in
            guard let self, self.connections[id] != nil else { return }
            let bytes = prefix + (data ?? Data())
            if let end = bytes.range(of: Data([13, 10, 13, 10]))?.lowerBound {
                let callback = Self.callback(headers: Data(bytes.prefix(end)), redirect: redirect)
                self.respond(id, callback: callback)
            } else if !eof, error == nil { self.receive(id, redirect: redirect, prefix: bytes) }
            else { self.cancel(id) }
        }
    }

    static func callback(headers: Data, redirect: URL) -> URL? {
        guard let decoded = String(data: headers, encoding: .utf8), let port = redirect.port else { return nil }
        let lines = decoded.components(separatedBy: "\r\n")
        guard let request = lines.first?.split(separator: " ", omittingEmptySubsequences: false), request.count == 3,
              request[0] == "GET", request[2] == "HTTP/1.1", request[1].hasPrefix("/auth/callback?"),
              request[1].utf8.allSatisfy({ (33...126).contains($0) && $0 != 35 && $0 != 92 }) else { return nil }
        var host: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line[..<colon].isEmpty,
                  line[..<colon].utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
            switch line[..<colon].lowercased() {
            case "host":
                guard host == nil else { return nil }
                host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            case "content-length", "transfer-encoding": return nil
            default: break
            }
        }
        guard host == "127.0.0.1:\(port)" else { return nil }
        return URL(string: "http://127.0.0.1:\(port)" + request[1])
    }

    private func respond(_ id: UUID, callback: URL?) {
        guard let connection = connections[id] else { return }
        let status = callback == nil ? "400 Bad Request" : "200 OK"
        let message = callback == nil ? "Invalid sign-in callback." : "Return to Mock Interview to check sign-in."
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(message.utf8.count)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n" + message
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self, self.connections[id] != nil else { return }
            self.cancel(id)
            if let callback { self.callbacks.continuation.yield(callback) }
        })
    }

    private func cancel(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func close() { queue.async { self.stop(nil) } }

    private func stop(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections = [:]
        ready.continuation.finish(throwing: error)
        callbacks.continuation.finish(throwing: error)
    }
}
#endif
