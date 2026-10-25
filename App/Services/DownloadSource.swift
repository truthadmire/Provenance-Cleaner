import Darwin
import Foundation

/// Finder's "Where from": the `kMDItemWhereFroms` extended attribute, a binary
/// property list of strings. Browsers record the file's link first, then the
/// page it was downloaded from. It lives on the file system, not in the file.
enum DownloadSource {
    static let attribute = "com.apple.metadata:kMDItemWhereFroms"
    static let maximumEntries = 8
    static let maximumEntryLength = 4096

    /// The recorded entries, or none when the attribute is absent or unreadable.
    static func read(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size,
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { return [] }
            if let entries = value as? [Any] { return entries.compactMap { $0 as? String } }
            return (value as? String).map { [$0] } ?? []
        }
    }

    static func write(_ entries: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            let status = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// Returns whether an attribute was there to remove.
    @discardableResult
    static func remove(from url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return removexattr(path, attribute, XATTR_NOFOLLOW) == 0
        }
    }

    /// Copies only the contents of `sourceURL`, so none of the original's
    /// file-system metadata comes along, and records `entries` on the copy.
    static func makeCopy(of sourceURL: URL, at destinationURL: URL, entries: [String]) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        try sourceURL.withUnsafeFileSystemRepresentation { source in
            try destinationURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { throw CocoaError(.fileWriteInvalidFileName) }
                guard copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        try write(entries, to: destinationURL)
    }
}
