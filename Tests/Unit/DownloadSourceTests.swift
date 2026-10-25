import Darwin
import Foundation
import XCTest
@testable import ProvenanceCleaner

final class DownloadSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceCleanerDownloadSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWritesTheBinaryListFinderReadsAndRemovesIt() throws {
        let file = try write("report.docx", "contents")
        XCTAssertEqual(DownloadSource.read(at: file), [])

        try DownloadSource.write(["https://example.invalid/report.docx", "https://example.invalid/"], to: file)

        XCTAssertEqual(DownloadSource.read(at: file), ["https://example.invalid/report.docx", "https://example.invalid/"])
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: try XCTUnwrap(rawAttribute(on: file)), format: &format)
        XCTAssertEqual(format, .binary)
        XCTAssertTrue(DownloadSource.remove(from: file))
        XCTAssertFalse(DownloadSource.remove(from: file))
        XCTAssertEqual(DownloadSource.read(at: file), [])
    }

    func testReadIgnoresValuesThatAreNotAListOfStrings() throws {
        let file = try write("note.txt", "contents")
        try setRawAttribute(Data("not a property list".utf8), on: file)
        XCTAssertEqual(DownloadSource.read(at: file), [])

        let single = try PropertyListSerialization.data(fromPropertyList: "https://example.invalid/", format: .binary, options: 0)
        try setRawAttribute(single, on: file)
        XCTAssertEqual(DownloadSource.read(at: file), ["https://example.invalid/"])
    }

    func testMakeCopyKeepsOnlyTheContentsAndRecordsTheNewSource() throws {
        let original = try write("original.pdf", "original bytes")
        try DownloadSource.write(["https://generator.invalid/original.pdf"], to: original)
        try setRawAttribute(Data("user data".utf8), named: "com.example.keep", on: original)
        let copy = root.appendingPathComponent("copy.pdf")

        try DownloadSource.makeCopy(of: original, at: copy, entries: ["https://example.invalid/report.pdf"])

        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "original bytes")
        XCTAssertEqual(DownloadSource.read(at: copy), ["https://example.invalid/report.pdf"])
        XCTAssertNil(rawAttribute(named: "com.example.keep", on: copy), "nothing else from the original comes along")
        XCTAssertEqual(DownloadSource.read(at: original), ["https://generator.invalid/original.pdf"], "the original is untouched")
        XCTAssertThrowsError(try DownloadSource.makeCopy(of: original, at: copy, entries: ["x"]), "never overwrites")
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func setRawAttribute(_ data: Data, named name: String = DownloadSource.attribute, on url: URL) throws {
        let status = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func rawAttribute(named name: String = DownloadSource.attribute, on url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        return data
    }
}
