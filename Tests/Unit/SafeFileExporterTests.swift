import Foundation
import XCTest
@testable import ProvenanceCleaner

final class SafeFileExporterTests: XCTestCase {
    func testCopyExportNeverOverwritesExistingDestination() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let staged = try fixture.write("stage.txt", "cleaned")
        let requested = try fixture.write("draft.cleaned.txt", "existing")
        let exporter = SafeFileExporter()

        let exported = try await exporter.exportCopy(from: staged, to: requested)

        XCTAssertEqual(exported.lastPathComponent, "draft.cleaned 2.txt")
        XCTAssertEqual(try String(contentsOf: requested, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "cleaned")
    }

    func testReplaceCreatesNoClobberBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let staged = try fixture.write("staged.txt", "cleaned")
        let exporter = SafeFileExporter()

        let replaced = try await exporter.replaceOriginal(from: staged, originalURL: original)

        XCTAssertEqual(replaced, original)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "cleaned")
        XCTAssertEqual(
            try String(contentsOf: original.appendingPathExtension("bak"), encoding: .utf8),
            "original"
        )
    }

    func testReplaceRefusesExistingBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let staged = try fixture.write("staged.txt", "cleaned")
        _ = try fixture.write("draft.txt.bak", "pristine backup")
        let exporter = SafeFileExporter()

        do {
            _ = try await exporter.replaceOriginal(from: staged, originalURL: original)
            XCTFail("Expected replacement to be refused")
        } catch let error as FileExportError {
            guard case .backupAlreadyExists = error else {
                return XCTFail("Unexpected export error: \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(
            try String(contentsOf: original.appendingPathExtension("bak"), encoding: .utf8),
            "pristine backup"
        )
    }

    func testReplaceFailureRetainsRecoveryBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let missingStaged = fixture.root.appendingPathComponent("missing.txt")
        let exporter = SafeFileExporter()

        do {
            _ = try await exporter.replaceOriginal(from: missingStaged, originalURL: original)
            XCTFail("Expected replacement to fail for a missing staged output")
        } catch {
            // Expected: the recovery assertions below are the contract.
        }

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        XCTAssertEqual(
            try String(contentsOf: original.appendingPathExtension("bak"), encoding: .utf8),
            "original"
        )
    }
}

private struct ExportFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceCleanerExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
