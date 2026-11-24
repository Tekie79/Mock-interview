import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EventStreamParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var messageSize = 0

    mutating func receive(_ bytes: Data, emit: (String) throws -> Void) throws {
        for byte in bytes {
            if byte != 10 {
                guard line.count < 262_144 else { throw ProviderFailure.malformedEvent }
                line.append(byte)
                continue
            }
            if line.last == 13 { line.removeLast() }
            guard let field = String(data: line, encoding: .utf8) else {
                throw ProviderFailure.malformedEvent
            }
            line.removeAll(keepingCapacity: true)
            if field.isEmpty {
                if !dataLines.isEmpty { try emit(dataLines.joined(separator: "\n")) }
                dataLines.removeAll(keepingCapacity: true)
                messageSize = 0
            } else if field.hasPrefix("data:") {
                var value = field.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                messageSize += value.utf8.count + 1
                guard messageSize <= 262_144 else { throw ProviderFailure.malformedEvent }
                dataLines.append(String(value))
            }
        }
    }
}

final class StreamingHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Decode = @Sendable (String) throws -> Event

    enum Event {
        case ignore
        case text(String)
        case usage(TokenUsage)
        case complete(TokenUsage? = nil)
    }

    private let output: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    private let decode: Decode
    private var parser = EventStreamParser()
    private var finished = false
    private var emittedText = false

    private init(output: AsyncThrowingStream<GenerationEvent, Error>.Continuation, decode: @escaping Decode) {
        self.output = output
        self.decode = decode
    }

    static func start(_ request: URLRequest, decode: @escaping Decode) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, output) = AsyncThrowingStream<GenerationEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(512))
        let receiver = StreamingHTTP(output: output, decode: decode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        output.onTermination = { _ in session.invalidateAndCancel() }
        task.resume()
        return stream
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try OpenAIResponsesClient.validate(response)
            guard (response as? HTTPURLResponse)?.mimeType == "text/event-stream" else {
                throw ProviderFailure.malformedEvent
            }
            completionHandler(.allow)
        } catch {
            finish(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        do {
            // Keep parser mutation separate from applying decoded events to avoid overlapping access.
            var messages: [String] = []
            try parser.receive(data) { messages.append($0) }
            for message in messages where !finished {
                switch try decode(message) {
                case .ignore: break
                case .text(let text):
                    if !text.isEmpty {
                        emittedText = true
                        if case .dropped = output.yield(.text(text)) { throw CaptureFailure.bufferOverrun }
                    }
                case .usage(let usage):
                    if case .dropped = output.yield(.usage(usage)) { throw CaptureFailure.bufferOverrun }
                case .complete(let usage):
                    if let usage, case .dropped = output.yield(.usage(usage)) {
                        throw CaptureFailure.bufferOverrun
                    }
                    finish(emittedText ? nil : ProviderFailure.malformedEvent)
                }
            }
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure: ProviderFailure = (error as? URLError)?.code == .timedOut ? .timeout : .disconnected
        finish(failure)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        output.finish(throwing: error)
    }
}
