import Foundation
import XCTest
@testable import ConversationCore
#if os(macOS)
import CoreGraphics
import CoreText
#endif

final class KnowledgeStoreTests: XCTestCase {
    func testProfileTrainingRoundTripsAndBroadExamplesRespectIsolationAndExclusion() async throws {
        let store = try KnowledgeStore()
        let original = InterviewProfile(name: "Synthetic profile")
        try await store.save(original)
        let old = try await store.profiles()
        XCTAssertNil(old.first?.answerTraining)
        var profile = original
        profile.answerTraining = .init(skills: "SQL", speakingSample: "I start with a concrete example.")
        try await store.save(profile)
        let updated = try await store.profiles()
        XCTAssertEqual(updated.first?.answerTraining, profile.answerTraining)

        let another = InterviewProfile(name: "Another profile")
        try await store.save(another)
        let story = ExperienceFact(category: ExperienceFact.projectStoryCategory,
                                   claim: "Warehouse delivery project", status: .confirmed)
        try await store.save(story, profile: profile.id)
        try await store.save(.init(category: ExperienceFact.projectStoryCategory,
                                   claim: "Excluded project story", status: .rejected), profile: profile.id)
        try await store.save(.init(claim: "Built a monitoring app.", status: .confirmed), profile: another.id)
        let resume = ProfileDocument(kind: .resume, title: "Resume.md", text: "- Tools: SQL and PostgreSQL\n- Built an ingestion pipeline.")
        let job = ProfileDocument(kind: .jobDescription, title: "Role.md", text: "Built cloud pipelines for finance.")
        try await store.add(resume, to: profile.id)
        try await store.add(job, to: profile.id)
        let examples = try await store.pastWorkExamples(profile: profile.id)
        XCTAssertEqual(examples.map(\.claim), [story.claim, "Built an ingestion pipeline."])
    }
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

    func testLegacyUpgradePreservesPendingFactsAndExplicitExclusions() async throws {
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
        XCTAssertEqual(facts.map(\.status), [.pending, .pending, .rejected])
        XCTAssertEqual(facts.first?.documentID, resume.id)
        XCTAssertEqual(facts.first?.locator, pendingImport.locator)
        let usable = try await updated.retrieve("instrumentation replay payments", profile: profile.id)
        XCTAssertTrue(usable.isEmpty)

        let reopened = try KnowledgeStore(url: url)
        let stable = try await reopened.facts(profile: profile.id)
        XCTAssertEqual(stable, facts)
        pendingImport.status = .confirmed
        try await reopened.save(pendingImport, profile: profile.id)
        let enabled = try await reopened.retrieve("instrumentation replay payments", profile: profile.id)
        XCTAssertEqual(enabled.map(\.id), [pendingImport.id])
    }

    func testWrappedClaimsKeepSourceSpanAndIncompleteClaimsStayOut() async throws {
        let store = try KnowledgeStore()
        let profile = InterviewProfile(name: "Fixture")
        try await store.save(profile)
        let text = """
            - Migrated telemetry records from
              local CSV archives into the reporting database.
            - Coordinated and
            - Built a schema validator.
            including an unsupported fragment.
            """
        let document = ProfileDocument(kind: .resume, title: "Fixture.md", text: text)
        try await store.add(document, to: profile.id)
        let facts = try await store.facts(profile: profile.id)
        XCTAssertEqual(facts.map(\.claim), ["Migrated telemetry records from local CSV archives into the reporting database.",
                                          "Built a schema validator."])
        XCTAssertEqual(facts.map(\.locator), ["Text lines 1–2", "Text line 4"])
        XCTAssertTrue(facts.allSatisfy { $0.sourceTitle == "Fixture.md" && $0.status == .confirmed })
        let stored = try await store.documents(profile: profile.id)
        XCTAssertEqual(stored.first?.text, text)
    }

    #if os(macOS)
    func testPDFTwoColumnsAreExtractedSeparatelyWithPageProvenance() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var rect = CGRect(x: 0, y: 0, width: 600, height: 800)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &rect, nil))
        pdf.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for (x, y, text) in [(30, 710, "Migrated audit events from"), (340, 710, "Built a data quality monitor."),
                             (30, 692, "a CSV archive into PostgreSQL."), (340, 692, "Reviewed the daily incident log.")] {
            pdf.textPosition = CGPoint(x: x, y: y)
            let line = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(line), pdf)
        }
        pdf.endPDFPage()
        pdf.closePDF()
        let store = try KnowledgeStore()
        let profile = InterviewProfile(name: "Fixture")
        try await store.save(profile)
        try await store.add(ProfileDocument.read(url, kind: .resume), to: profile.id)
        let facts = try await store.facts(profile: profile.id)
        XCTAssertEqual(facts.map(\.claim), ["Migrated audit events from a CSV archive into PostgreSQL.",
                                          "Built a data quality monitor.", "Reviewed the daily incident log."])
        XCTAssertTrue(facts.first?.locator.hasPrefix("Page 1, column 1") == true)
        XCTAssertTrue(facts.last?.locator.hasPrefix("Page 1, column 2") == true)
    }
    #endif
}
