import Foundation
import XCTest
@testable import ProvenanceCleaner

final class SupportedFileTypesTests: XCTestCase {
    func testTheSuggestedCopyNameDoesNotSayTheFileWasCleaned() {
        XCTAssertEqual(SupportedFileTypes.copyFilename(for: URL(fileURLWithPath: "/tmp/Essay draft.docx")), "Essay draft 2.docx")
        XCTAssertEqual(SupportedFileTypes.copyFilename(for: URL(fileURLWithPath: "/tmp/notes")), "notes 2")
    }

    func testInputExpansionAcceptsFilesButNeverEnumeratesDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceCleanerInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nestedFile = root.appendingPathComponent("nested.txt")
        try Data("content".utf8).write(to: nestedFile)

        XCTAssertTrue(SupportedFileTypes.expandInputURLs([root]).isEmpty)
        XCTAssertEqual(
            SupportedFileTypes.expandInputURLs([nestedFile, nestedFile]),
            [nestedFile]
        )
    }
}
