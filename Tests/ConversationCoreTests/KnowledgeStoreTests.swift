import Foundation
import XCTest
@testable import ConversationCore

final class KnowledgeStoreTests: XCTestCase {
    func testMarkdownAttachmentsAreUsableWithCleanFactsAndSourceLines() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resumeURL = folder.appendingPathComponent("Resume.MD")
        let jobURL = folder.appendingPathComponent("Role.markdown")
        let notesURL = folder.appendingPathComponent("Project.md")
        let resumeText = "# Practice résumé\n\n- Designed a bounded retry queue.\n~~~text\nThis is a code block.\n~~~"
        let jobText = "## Target role\n* Own the retry platform."
        let notesText = "## Project notes\n* Documented the failure scenarios."
        try resumeText.write(to: resumeURL, atomically: true, encoding: .utf8)
        try jobText.write(to: jobURL, atomically: true, encoding: .utf8)
        try notesText.write(to: notesURL, atomically: true, encoding: .utf8)
        let attachments = try [ProfileDocument.read(resumeURL, kind: .resume), .read(jobURL, kind: .jobDescription),
                               .read(notesURL, kind: .project)]

        let store = try KnowledgeStore()
        let profile = InterviewProfile(name: "Markdown fixture")
        try await store.save(profile)
        for document in attachments { try await store.add(document, to: profile.id) }
        let saved = try await store.documents(profile: profile.id)
        XCTAssertEqual(saved.map(\.kind), [.resume, .jobDescription, .project])
        XCTAssertEqual(saved.map(\.title), ["Resume.MD", "Role.markdown", "Project.md"])
        XCTAssertEqual(saved.map(\.text), [resumeText, jobText, notesText])

        let facts = try await store.facts(profile: profile.id)
        XCTAssertEqual(facts.map(\.claim), ["Designed a bounded retry queue.", "Documented the failure scenarios."])
        XCTAssertEqual(facts.map(\.documentID), [saved[0].id, saved[2].id])
        XCTAssertEqual(facts.map(\.locator), ["Text line 3", "Text line 2"])
        XCTAssertTrue(facts.allSatisfy { $0.status == .confirmed })
        let matches = try await store.retrieve("bounded retry queue", profile: profile.id)
        XCTAssertEqual(matches.map(\.claim), ["Designed a bounded retry queue."])
    }

    func testMarkdownReaderRejectsEmptyOrUnsupportedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("Empty.md")
        let unsupported = folder.appendingPathComponent("Image.png")
        try " \n\t".write(to: empty, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: unsupported)
        XCTAssertThrowsError(try ProfileDocument.read(empty, kind: .resume)) {
            XCTAssertEqual($0 as? StorageFailure, .emptyDocument)
        }
        XCTAssertThrowsError(try ProfileDocument.read(unsupported, kind: .resume)) {
            XCTAssertEqual($0 as? StorageFailure, .unsupportedFormat)
        }
    }

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
        XCTAssertEqual(evidence.status, .confirmed)
        evidence.status = .rejected
        try await store.save(evidence, profile: mine.id)
        try await store.save(.init(claim: "Draft about the retry queue", status: .pending), profile: mine.id)
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

    func testLegacyUpgradeEnablesExistingProfileFactsAndPreservesExclusions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("legacy.sqlite")
        let legacy = try KnowledgeStore(url: url)
        let profile = InterviewProfile(name: "Legacy fixture")
        try await legacy.save(profile)
        let resume = ProfileDocument(kind: .resume, title: "Resume.md", text: "- Designed queue instrumentation.")
        try await legacy.add(resume, to: profile.id)
        let imported = try await legacy.facts(profile: profile.id)
        var pendingImport = try XCTUnwrap(imported.first)
        pendingImport.status = .pending
        let manual = ExperienceFact(claim: "Maintained a replay tool.", status: .pending)
        let excluded = ExperienceFact(documentID: resume.id, claim: "Owned payments.", status: .rejected)
        for fact in [pendingImport, manual, excluded] { try await legacy.save(fact, profile: profile.id) }
        try SQLiteDatabase(path: url.path).execute("PRAGMA user_version = 3")

        let updated = try KnowledgeStore(url: url)
        let facts = try await updated.facts(profile: profile.id)
        XCTAssertEqual(facts.map(\.status), [.confirmed, .confirmed, .rejected])
        XCTAssertEqual(facts.first?.documentID, resume.id)
        XCTAssertEqual(facts.first?.locator, pendingImport.locator)
        let usable = try await updated.retrieve("instrumentation replay payments", profile: profile.id)
        XCTAssertEqual(Set(usable.map(\.id)), Set([pendingImport.id, manual.id]))

        let reopened = try KnowledgeStore(url: url)
        let stable = try await reopened.facts(profile: profile.id)
        XCTAssertEqual(stable, facts)
    }
}
