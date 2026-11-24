import Foundation
import XCTest
@testable import ConversationCore

final class DOCXTests: XCTestCase {
    func testOfficeZipReadsDeflatedWordParagraphs() throws {
        let archive = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIABi2eF1AXEnxtQAAABEBAAARAAAAd29yZC9kb2N1bWVudC54bWxtjzEOwjAMRa8SZWCjKQwIlbZszAxwgJAYGqmxIydQensSJMQAy7Msfz/Z7f7pR/EAjo6wk6uqlgLQkHV46+T5dFhu5b5vp8aSuXvAJHIeYzN1ckgpNEpFM4DXsaIAmGdXYq9TbvmmJmIbmAzEmHV+VOu63iivHcqivJCdSw0FXJD6I0PQDFbEGdMAyRmx0D7sBMPDwaQvIwikBLFqVckX8pvhV6VN3gdBOM7/4upzgvq+178AUEsBAhQDFAAAAAgAGLZ4XUBcSfG1AAAAEQEAABEAAAAAAAAAAAAAAIABAAAAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAABAAEAPwAAAOQAAAAAAA=="))
        XCTAssertEqual(try DOCXDocument.text(from: archive),
                       "Prepared synthetic & reviewable notes.\nPractice only.")
        XCTAssertThrowsError(try DOCXDocument.text(from: Data(archive.dropLast())))
    }
}
