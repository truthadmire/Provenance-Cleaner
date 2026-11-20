import Darwin
import Foundation
import ImageIO

/// Why a file is not shown in the Review tab's preview.
enum PreviewFileError: LocalizedError, Equatable {
    /// A symlink, folder, pipe, device or anything else that isn't a plain file.
    case notRegularFile
    /// Bigger than the engine will take, so bigger than the preview reads.
    case tooLarge
    /// The image's header claims more pixels than the engine would decode.
    case imageTooLarge
    /// The file couldn't be opened, read or decoded.
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notRegularFile: String(localized: "This file can't be previewed.")
        case .tooLarge, .imageTooLarge: String(localized: "Too large to preview.")
        case .unreadable: String(localized: "This file couldn't be read.")
        }
    }
}

/// The same gate the engine applies to what it is given (no symlinks, regular
/// files only, at most `BundledWatermarkEngine.maximumInputBytes`), applied
/// before the Review tab reads or hands a file to Quick Look.
enum PreviewFileGate {
    static let maximumBytes: Int64 = BundledWatermarkEngine.maximumInputBytes

    /// Opens `url` without following a final symlink and without blocking on a
    /// pipe, and checks the open file itself, so a swap after the check can't
    /// redirect the read.
    static func open(_ url: URL, maximumBytes: Int64 = maximumBytes) throws -> FileHandle {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ELOOP, EISDIR, ENXIO, EOPNOTSUPP: throw PreviewFileError.notRegularFile
            default: throw PreviewFileError.unreadable
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            Darwin.close(descriptor)
            throw PreviewFileError.unreadable
        }
        do {
            try validate(info, maximumBytes: maximumBytes)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The whole file, read through `open`. A file that grew past the cap
    /// after it was checked is refused, not cut short.
    static func readAll(_ url: URL, maximumBytes: Int64 = maximumBytes) throws -> Data {
        let handle = try open(url, maximumBytes: maximumBytes)
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
        } catch {
            throw PreviewFileError.unreadable
        }
        guard Int64(data.count) <= maximumBytes else { throw PreviewFileError.tooLarge }
        return data
    }

    /// Checks the path itself, without following a symlink, for viewers such
    /// as Quick Look that take a URL rather than an open file.
    static func check(_ url: URL, maximumBytes: Int64 = maximumBytes) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        guard result == 0 else { throw PreviewFileError.unreadable }
        try validate(info, maximumBytes: maximumBytes)
    }

    private static func validate(_ info: stat, maximumBytes: Int64) throws {
        guard info.st_mode & S_IFMT == S_IFREG else { throw PreviewFileError.notRegularFile }
        guard Int64(info.st_size) <= maximumBytes else { throw PreviewFileError.tooLarge }
    }
}

/// Decodes an image for the preview off the main thread, with the same
/// file gate, a pixel cap read from the header before any decode, and a
/// downsampled bitmap no bigger than the pane can use.
enum ImagePreviewLoader {
    /// Pillow refuses images above twice its MAX_IMAGE_PIXELS (89,478,485)
    /// as decompression bombs, so the engine never processes anything larger.
    static let maximumPixels = 2 * 89_478_485
    static let maximumPixelSize = 4096

    static func load(_ url: URL) throws -> CGImage {
        let data = try PreviewFileGate.readAll(url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            throw PreviewFileError.unreadable
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else { throw PreviewFileError.imageTooLarge }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw PreviewFileError.unreadable
        }
        return image
    }
}
