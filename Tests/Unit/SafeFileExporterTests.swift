import Darwin
import Foundation
import XCTest
@testable import ProvenanceCleaner

final class SafeFileExporterTests: XCTestCase {
    private let whereFrom = DownloadSource.attribute

    func testSaveCopyWritesExactlyTheChosenFileEvenWhenItExists() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let staged = try fixture.write("stage.txt", "cleaned")
        let chosen = try fixture.write("draft.cleaned.txt", "existing")
        try fixture.setAttribute(whereFrom, "https://example.invalid/old", on: chosen)
        let exporter = SafeFileExporter()

        // The save panel already confirmed the overwrite; the sandbox grants only this URL.
        let saved = try await exporter.saveCopy(from: staged, to: chosen)

        XCTAssertEqual(saved, chosen)
        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), "cleaned")
        XCTAssertNil(fixture.attribute(whereFrom, on: chosen), "the overwritten file's download source must not survive")
        XCTAssertEqual(try fixture.names(), ["draft.cleaned.txt", "stage.txt"], "no temporary or numbered files are left")
    }

    func testSaveCopyCreatesANewFile() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let staged = try fixture.write("stage.txt", "cleaned")
        let chosen = fixture.root.appendingPathComponent("new name.txt")

        let saved = try await SafeFileExporter().saveCopy(from: staged, to: chosen)

        XCTAssertEqual(saved, chosen)
        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), "cleaned")
    }

    func testFolderExportNumbersTheNameInsteadOfOverwriting() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let staged = try fixture.write("stage.txt", "cleaned")
        _ = try fixture.write("draft.cleaned.txt", "existing")
        let source = fixture.root.appendingPathComponent("draft.txt")

        let exported = try await SafeFileExporter().exportCopy(from: staged, sourceURL: source, into: fixture.root)

        XCTAssertEqual(exported.lastPathComponent, "draft.cleaned 2.txt")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("draft.cleaned.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), "cleaned")
    }

    func testReplaceCreatesNoClobberBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let staged = try fixture.write("staged.txt", "cleaned")

        let result = try await SafeFileExporter().replaceOriginal(from: staged, originalURL: original)

        XCTAssertEqual(result.originalURL, original)
        XCTAssertEqual(result.backupURL, original.appendingPathExtension("bak"))
        XCTAssertFalse(result.removedDownloadSource)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "cleaned")
        XCTAssertEqual(try String(contentsOf: result.backupURL, encoding: .utf8), "original")
        XCTAssertEqual(try fixture.names(), ["draft.txt", "draft.txt.bak", "staged.txt"], "no temporary files are left")
    }

    func testReplaceRemovesOnlyTheDownloadSource() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        try fixture.setAttribute(whereFrom, "https://generator.invalid/file", on: original)
        try fixture.setAttribute("com.example.keep", "user data", on: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
        let staged = try fixture.write("staged.txt", "cleaned")

        let result = try await SafeFileExporter().replaceOriginal(from: staged, originalURL: original)

        XCTAssertTrue(result.removedDownloadSource)
        XCTAssertNil(fixture.attribute(whereFrom, on: original))
        XCTAssertEqual(fixture.attribute("com.example.keep", on: original), "user data")
        let permissions = try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
        XCTAssertEqual(fixture.attribute(whereFrom, on: result.backupURL), "https://generator.invalid/file", "the backup keeps everything")
    }

    func testSavedCopiesKeepTheDownloadSourceGivenToTheCopy() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let entries = ["https://example.invalid/report.docx", "https://example.invalid/"]
        let staged = try fixture.write("stage.txt", "cleaned")
        try DownloadSource.write(entries, to: staged)
        let existing = try fixture.write("existing.txt", "old")
        try DownloadSource.write(["https://old.invalid/"], to: existing)
        let exporter = SafeFileExporter()

        let fresh = try await exporter.saveCopy(from: staged, to: fixture.root.appendingPathComponent("fresh.txt"))
        let overwritten = try await exporter.saveCopy(from: staged, to: existing)
        let exported = try await exporter.exportCopy(
            from: staged, sourceURL: fixture.root.appendingPathComponent("draft.txt"), into: fixture.root
        )

        for url in [fresh, overwritten, exported] {
            XCTAssertEqual(DownloadSource.read(at: url), entries, url.lastPathComponent)
        }
    }

    func testReplaceGivesTheOriginalTheCopysDownloadSource() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        try DownloadSource.write(["https://generator.invalid/file"], to: original)
        let staged = try fixture.write("staged.txt", "cleaned")
        try DownloadSource.write(["https://example.invalid/report.txt"], to: staged)

        let result = try await SafeFileExporter().replaceOriginal(from: staged, originalURL: original)

        XCTAssertFalse(result.removedDownloadSource)
        XCTAssertEqual(result.downloadSource, ["https://example.invalid/report.txt"])
        XCTAssertEqual(DownloadSource.read(at: original), ["https://example.invalid/report.txt"])
        XCTAssertEqual(DownloadSource.read(at: result.backupURL), ["https://generator.invalid/file"], "the backup keeps everything")
    }

    func testReplaceRefusesExistingBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let staged = try fixture.write("staged.txt", "cleaned")
        _ = try fixture.write("draft.txt.bak", "pristine backup")

        do {
            _ = try await SafeFileExporter().replaceOriginal(from: staged, originalURL: original)
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

    func testReplaceWithAMissingCopyLeavesTheOriginalAndNoBackup() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let missingStaged = fixture.root.appendingPathComponent("missing.txt")

        do {
            _ = try await SafeFileExporter().replaceOriginal(from: missingStaged, originalURL: original)
            XCTFail("Expected replacement to fail for a missing staged output")
        } catch {
            XCTAssertEqual(error as? FileExportError, .noStagedOutput)
        }

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        // No stray backup, so a later attempt isn't blocked.
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathExtension("bak").path))
    }

    func testReplaceRechecksTheOriginalAndLeavesAChangedOneAlone() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let original = try fixture.write("draft.txt", "original")
        let staged = try fixture.write("staged.txt", "cleaned")
        let expected = try XCTUnwrap(FileFingerprint(url: original))
        // Edited after the copy was built, but before the replace runs.
        try Data("edited later, longer".utf8).write(to: original)

        do {
            _ = try await SafeFileExporter().replaceOriginal(from: staged, originalURL: original, expectedOriginal: expected)
            XCTFail("Expected the changed original to be left alone")
        } catch {
            XCTAssertEqual(error as? FileExportError, .originalChanged)
        }

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "edited later, longer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathExtension("bak").path))
    }

    func testFingerprintNoticesAnEdit() throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let file = try fixture.write("draft.txt", "first")
        let before = try XCTUnwrap(FileFingerprint(url: file))
        XCTAssertEqual(FileFingerprint(url: file), before)

        try Data("second version".utf8).write(to: file)

        XCTAssertNotEqual(FileFingerprint(url: file), before)
        XCTAssertNil(FileFingerprint(url: fixture.root.appendingPathComponent("missing.txt")))
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

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func setAttribute(_ name: String, _ value: String, on url: URL) throws {
        let data = Data(value.utf8)
        let status = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func attribute(_ name: String, on url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
