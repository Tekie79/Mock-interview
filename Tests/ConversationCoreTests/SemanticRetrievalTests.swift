import XCTest
@testable import ConversationCore

private actor TestEmbedding: TextEmbeddingProvider {
    nonisolated let indexIdentity: String
    private(set) var submitted: [String] = []

    init(model: String) { indexIdentity = model }

    func embed(_ text: [String]) async throws -> [[Double]] {
        submitted.append(contentsOf: text)
        return text.map { _ in [1, 0, 0] }
    }
}

final class SemanticRetrievalTests: XCTestCase {
    func testHybridUsesOnlyCurrentModelAndApprovedFacts() async throws {
        let store = try KnowledgeStore()
        let profile = InterviewProfile(name: "Practice")
        try await store.save(profile)
        var approved = ExperienceFact(claim: "Queued expensive work asynchronously.", status: .confirmed)
        try await store.save(approved, profile: profile.id)
        try await store.save(ExperienceFact(claim: "Unverified project details."), profile: profile.id)
        let embedding = TestEmbedding(model: "original-model")
        let indexed = try await store.indexConfirmedFacts(profile: profile.id, provider: embedding)
        XCTAssertEqual(indexed, 1)
        let submitted = await embedding.submitted
        XCTAssertEqual(submitted, [approved.claim])

        let query = "Explain load shedding."
        let keyword = try await store.retrieve(query, profile: profile.id)
        XCTAssertTrue(keyword.isEmpty)
        let hybrid = try await store.hybridRetrieve(query, profile: profile.id, provider: embedding)
        XCTAssertEqual(hybrid, [approved])
        let differentModel = TestEmbedding(model: "replacement-model")
        let obsolete = try await store.hybridRetrieve(query, profile: profile.id, provider: differentModel)
        XCTAssertTrue(obsolete.isEmpty)
        let uncachedRequests = await differentModel.submitted
        XCTAssertTrue(uncachedRequests.isEmpty)

        approved.status = .rejected
        try await store.save(approved, profile: profile.id)
        let revoked = try await store.hybridRetrieve(query, profile: profile.id, provider: embedding)
        XCTAssertTrue(revoked.isEmpty)
    }
}
