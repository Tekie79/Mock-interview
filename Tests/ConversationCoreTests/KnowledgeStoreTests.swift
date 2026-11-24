import Foundation
import XCTest
@testable import ConversationCore

final class KnowledgeStoreTests: XCTestCase {
    func testRetrievalUsesOnlyConfirmedFactsInSelectedProfile() async throws {
        let store = try KnowledgeStore()
        let mine = InterviewProfile(name: "Primary")
        let other = InterviewProfile(name: "Other")
        try await store.save(mine)
        try await store.save(other)
        let resume = ProfileDocument(kind: .resume, title: "Practice résumé", text: "Designed a retry queue.")
        let job = ProfileDocument(kind: .jobDescription, title: "Practice role", text: "Own the retry platform.")
        try await store.add(resume, to: mine.id)
        try await store.add(job, to: mine.id)
        let facts = try await store.facts(profile: mine.id)
        var evidence = try XCTUnwrap(facts.first)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(evidence.status, .pending)
        let initial = try await store.retrieve("Explain retries and your retry queue", profile: mine.id)
        XCTAssertTrue(initial.isEmpty)

        evidence.status = .confirmed
        evidence.limitations = "Did not own the platform"
        try await store.save(evidence, profile: mine.id)
        try await store.save(ExperienceFact(claim: "Ran the retry platform", status: .confirmed), profile: other.id)
        let results = try await store.retrieve("Explain the retry queue", profile: mine.id)
        XCTAssertEqual(results, [evidence])
        XCTAssertTrue(results[0].promptText.contains(evidence.limitations))

        do {
            try await store.save(ExperienceFact(documentID: job.id, claim: job.text, status: .confirmed),
                                 profile: mine.id)
            XCTFail("Job descriptions cannot serve as evidence.")
        } catch StorageFailure.invalidRecord {}
        try await store.deleteDocument(resume.id, profile: mine.id)
        let deleted = try await store.retrieve("retry", profile: mine.id)
        XCTAssertTrue(deleted.isEmpty)
    }
}
