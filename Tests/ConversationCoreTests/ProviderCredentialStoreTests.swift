import Foundation
import XCTest
@testable import ConversationCore

private final class CredentialBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var values = ["openai": "synthetic-openai", "elevenlabs": "synthetic-elevenlabs"]
    private var reads: [String: Int] = [:]

    func load(_ account: String) -> String? {
        lock.withLock {
            reads[account, default: 0] += 1
            return values[account]
        }
    }

    func save(_ value: String, account: String) throws {
        guard value != "failed-write" else { throw ProviderFailure.requestRejected }
        lock.withLock { values[account] = value.isEmpty ? nil : value }
    }

    func readCount(_ account: String) -> Int {
        lock.withLock { reads[account, default: 0] }
    }

    func makeStore() -> ProviderCredentialStore {
        .init(read: { [self] in load($0) }, persist: { [self] in try save($0, account: $1) })
    }
}

final class ProviderCredentialStoreTests: XCTestCase {
    func testConcurrentConsumersReuseOneAuthorizedReadPerProvider() async {
        let backend = CredentialBackend()
        let store = backend.makeStore()
        async let transcription = store.load("openai")
        async let classification = store.load("openai")
        async let answers = store.load("openai")
        async let other = store.load("elevenlabs")
        let values = await [transcription, classification, answers, other]

        XCTAssertEqual(values, ["synthetic-openai", "synthetic-openai", "synthetic-openai", "synthetic-elevenlabs"])
        XCTAssertEqual(backend.readCount("openai"), 1)
        XCTAssertEqual(backend.readCount("elevenlabs"), 1)
    }

    func testSuccessfulEditsReplaceCacheAndMissingReadsCanBeRetried() async throws {
        let backend = CredentialBackend()
        let store = backend.makeStore()
        _ = await store.load("openai")
        try await store.save("replacement", account: "openai")
        do {
            try await store.save("failed-write", account: "openai")
            XCTFail("A failed Keychain write must surface an error.")
        } catch ProviderFailure.requestRejected {}
        let replacement = await store.load("openai")
        XCTAssertEqual(replacement, "replacement")
        XCTAssertEqual(backend.readCount("openai"), 1)

        try await store.save("", account: "openai")
        let removed = await store.load("openai")
        XCTAssertNil(removed)
        try backend.save("later-authorized-value", account: "openai")
        let retried = await store.load("openai")
        XCTAssertEqual(retried, "later-authorized-value")
        XCTAssertEqual(backend.readCount("openai"), 3)
    }
}
