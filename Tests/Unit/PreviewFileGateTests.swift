import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ProvenanceCleaner

/// The Review tab's preview applies the engine's file checks (no symlinks,
/// regular files only, 256 MiB) and an image pixel cap before reading.
final class PreviewFileGateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewFileGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCapIsTheEngineInputCap() {
        XCTAssertEqual(PreviewFileGate.maximumBytes, BundledWatermarkEngine.maximumInputBytes)
        XCTAssertEqual(PreviewFileGate.maximumBytes, 256 << 20)
    }

    func testARegularFileIsReadInFull() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertNoThrow(try PreviewFileGate.check(file))
        XCTAssertEqual(try PreviewFileGate.readAll(file), Data("hello".utf8))
        let handle = try PreviewFileGate.open(file)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.read(upToCount: 3), Data("hel".utf8))
    }

    func testASymlinkToARegularFileIsRefused() throws {
        let target = root.appendingPathComponent("target.png")
        try Data("x".utf8).write(to: target)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try PreviewFileGate.open(link)) {
            XCTAssertEqual($0 as? PreviewFileError, .notRegularFile)
        }
        XCTAssertThrowsError(try PreviewFileGate.check(link)) {
            XCTAssertEqual($0 as? PreviewFileError, .notRegularFile)
        }
        XCTAssertThrowsError(try ImagePreviewLoader.load(link))
    }

    func testADirectoryIsRefused() throws {
        let folder = root.appendingPathComponent("folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PreviewFileGate.open(folder)) {
            XCTAssertEqual($0 as? PreviewFileError, .notRegularFile)
        }
        XCTAssertThrowsError(try PreviewFileGate.check(folder)) {
            XCTAssertEqual($0 as? PreviewFileError, .notRegularFile)
        }
    }

    func testAPipeIsRefusedWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("pipe.txt")
        XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }, 0)

        let finished = expectation(description: "open returned")
        let box = ErrorBox()
        DispatchQueue.global().async {
            do {
                _ = try PreviewFileGate.open(fifo)
            } catch {
                box.error = error as? PreviewFileError
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(box.error, .notRegularFile)
        XCTAssertThrowsError(try PreviewFileGate.check(fifo)) {
            XCTAssertEqual($0 as? PreviewFileError, .notRegularFile)
        }
    }

    func testAFileOverTheCapIsRefusedAndOneAtTheCapIsAccepted() throws {
        let atCap = root.appendingPathComponent("at-cap.bin")
        let overCap = root.appendingPathComponent("over-cap.bin")
        for (url, size) in [(atCap, PreviewFileGate.maximumBytes), (overCap, PreviewFileGate.maximumBytes + 1)] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size)) // sparse, so cheap
            try handle.close()
        }

        XCTAssertNoThrow(try PreviewFileGate.check(atCap))
        XCTAssertNoThrow(try PreviewFileGate.open(atCap).close())
        XCTAssertThrowsError(try PreviewFileGate.check(overCap)) {
            XCTAssertEqual($0 as? PreviewFileError, .tooLarge)
        }
        XCTAssertThrowsError(try PreviewFileGate.open(overCap)) {
            XCTAssertEqual($0 as? PreviewFileError, .tooLarge)
        }
        XCTAssertThrowsError(try ImagePreviewLoader.load(overCap)) {
            XCTAssertEqual($0 as? PreviewFileError, .tooLarge)
        }
    }

    func testSmallPNGAndJPEGImagesStillPreviewAtFullSize() throws {
        for type in [UTType.png, UTType.jpeg] {
            let file = root.appendingPathComponent("small.\(type.preferredFilenameExtension!)")
            try encodedImage(width: 40, height: 30, type: type).write(to: file)

            let image = try ImagePreviewLoader.load(file)
            XCTAssertEqual(image.width, 40, "\(type)")
            XCTAssertEqual(image.height, 30, "\(type)")
        }
    }

    func testALargeImageIsDownsampledForThePane() throws {
        let data = try encodedImage(width: 5000, height: 2500, type: .png)
        let image = try ImagePreviewLoader.decode(data)
        XCTAssertEqual(max(image.width, image.height), ImagePreviewLoader.maximumPixelSize)
        XCTAssertEqual(image.width, 4096)
    }

    func testADecompressionBombIsRefusedByItsHeaderBeforeDecoding() throws {
        // 14,000 x 14,000 = 196 million pixels, over the cap, in about 24 KB.
        let file = root.appendingPathComponent("bomb.png")
        let bomb = try compressedBlankPNG(width: 14_000, height: 14_000)
        XCTAssertLessThan(bomb.count, 64 << 10)
        try bomb.write(to: file)

        XCTAssertThrowsError(try ImagePreviewLoader.load(file)) {
            XCTAssertEqual($0 as? PreviewFileError, .imageTooLarge)
        }
    }

    func testAnImageJustUnderThePixelCapIsStillDecodedAndDownsampled() throws {
        // 13,376 x 13,376 = 178,917,376 pixels, just under the cap.
        let image = try ImagePreviewLoader.decode(compressedBlankPNG(width: 13_376, height: 13_376))
        XCTAssertEqual(image.width, ImagePreviewLoader.maximumPixelSize)
        XCTAssertEqual(image.height, ImagePreviewLoader.maximumPixelSize)
    }

    func testThePixelCapMatchesTheEngineDecompressionLimit() {
        // Pillow raises DecompressionBombError above 2 * 89,478,485 pixels.
        XCTAssertEqual(ImagePreviewLoader.maximumPixels, 178_956_970)
    }

    func testGateErrorsHaveReadableMessages() {
        XCTAssertEqual(PreviewFileError.tooLarge.localizedDescription, "Too large to preview.")
        XCTAssertEqual(PreviewFileError.imageTooLarge.localizedDescription, "Too large to preview.")
        XCTAssertEqual(PreviewFileError.notRegularFile.localizedDescription, "This file can't be previewed.")
        XCTAssertEqual(PreviewFileError.unreadable.localizedDescription, "This file couldn't be read.")
    }

    // MARK: - Helpers

    private final class ErrorBox: @unchecked Sendable {
        var error: PreviewFileError?
    }

    private func encodedImage(width: Int, height: Int, type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A real, valid 1-bit grayscale PNG of `width` x `height` black pixels:
    /// tens of kilobytes on disk that would need hundreds of megabytes to
    /// decode. ImageIO won't report the size of a header with no plausible
    /// image data, so the image data is genuine.
    private func compressedBlankPNG(width: Int, height: Int) throws -> Data {
        precondition(width % 8 == 0)
        let raw = Data(count: (width / 8 + 1) * height) // filter byte 0 + zero bits per row
        var zlib = Data([0x78, 0x9C])
        zlib.append(try (raw as NSData).compressed(using: .zlib) as Data)
        // Adler-32 of all-zero bytes: a stays 1, b is the length mod 65521.
        zlib.append(contentsOf: bigEndian(UInt32(raw.count % 65_521) << 16 | 1))

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(contentsOf: bigEndian(UInt32(width)))
        ihdr.append(contentsOf: bigEndian(UInt32(height)))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0]) // 1-bit grayscale
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlib))
        png.append(chunk("IEND", Data()))
        return png
    }

    private func chunk(_ type: String, _ body: Data) -> Data {
        var result = Data(bigEndian(UInt32(body.count)))
        let typed = Data(type.utf8) + body
        result.append(typed)
        result.append(contentsOf: bigEndian(crc32(typed)))
        return result
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
