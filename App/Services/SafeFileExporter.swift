import Darwin
import Foundation

enum FileExportError: LocalizedError, Equatable, Sendable {
    case noStagedOutput
    case backupAlreadyExists(URL)
    case originalChanged
    case folderAccessDeclined(URL)

    /// True when the file system refused access, as the sandbox does for a
    /// new file beside a file the user granted on its own.
    static func isPermissionDenied(_ error: Error) -> Bool {
        var current: Error? = error
        while let nsError = current as NSError? {
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .noStagedOutput:
            "There is no copy to save."
        case let .backupAlreadyExists(url):
            "A backup already exists at \(url.path). Move it elsewhere before replacing the original."
        case .originalChanged:
            "The original changed after this copy was made. Update the copy, then try again."
        case let .folderAccessDeclined(folder):
            "A backup can't be written without permission to the folder “\(folder.lastPathComponent)”. Use Save copy instead, or try again and choose Allow."
        }
    }
}

struct ReplacementResult: Equatable, Sendable {
    let originalURL: URL
    let backupURL: URL
    /// The original's download-source attribute was carried over by the
    /// replace and has been removed again.
    let removedDownloadSource: Bool
}

actor SafeFileExporter {
    /// Finder's record of where a file was downloaded from. A replace would
    /// otherwise carry it from the original onto the cleaned file.
    static let downloadSourceAttribute = "com.apple.metadata:kMDItemWhereFroms"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes the copy to exactly the URL the user chose in the save panel.
    /// The panel has already confirmed overwriting an existing file, and in
    /// the sandbox only that URL is writable.
    func saveCopy(from stagedURL: URL, to destinationURL: URL) throws -> URL {
        let temporaryURL = try preparedTemporaryCopy(of: stagedURL, appropriateFor: destinationURL)
        defer { try? fileManager.removeItem(at: temporaryURL.deletingLastPathComponent()) }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        return destinationURL
    }

    /// Saves into a folder the user chose, numbering the name instead of
    /// overwriting anything already there.
    func exportCopy(from stagedURL: URL, sourceURL: URL, into directoryURL: URL) throws -> URL {
        let requested = directoryURL.appendingPathComponent(
            SupportedFileTypes.cleanedFilename(for: sourceURL),
            isDirectory: false
        )
        let destination = uniqueDestination(startingAt: requested)
        try fileManager.copyItem(at: stagedURL, to: destination)
        return destination
    }

    func replaceOriginal(from stagedURL: URL, originalURL: URL) throws -> ReplacementResult {
        let backupURL = originalURL.appendingPathExtension("bak")
        guard !fileManager.fileExists(atPath: backupURL.path) else {
            throw FileExportError.backupAlreadyExists(backupURL)
        }

        // Prepare the copy before touching anything next to the original, so
        // a missing or unreadable copy leaves no backup behind.
        let temporaryURL = try preparedTemporaryCopy(of: stagedURL, appropriateFor: originalURL)
        defer { try? fileManager.removeItem(at: temporaryURL.deletingLastPathComponent()) }

        try fileManager.copyItem(at: originalURL, to: backupURL)
        do {
            // Default options keep the original's permissions, dates, tags
            // and comments; only the download source is removed below.
            _ = try fileManager.replaceItemAt(
                originalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } catch {
            if fileManager.fileExists(atPath: originalURL.path) {
                // The original is intact, so the backup isn't needed and
                // would only block the next attempt.
                try? fileManager.removeItem(at: backupURL)
            } else if fileManager.fileExists(atPath: backupURL.path) {
                // Restore a copy while keeping the backup as a second path.
                try? fileManager.copyItem(at: backupURL, to: originalURL)
            }
            throw error
        }

        let removed = originalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return removexattr(path, Self.downloadSourceAttribute, XATTR_NOFOLLOW) == 0
        }
        return ReplacementResult(originalURL: originalURL, backupURL: backupURL, removedDownloadSource: removed)
    }

    private func preparedTemporaryCopy(of stagedURL: URL, appropriateFor destinationURL: URL) throws -> URL {
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            throw FileExportError.noStagedOutput
        }
        let directory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationURL,
            create: true
        )
        let temporaryURL = directory.appendingPathComponent(destinationURL.lastPathComponent)
        do {
            try fileManager.copyItem(at: stagedURL, to: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return temporaryURL
    }

    private func uniqueDestination(startingAt requestedURL: URL) -> URL {
        guard fileManager.fileExists(atPath: requestedURL.path) else { return requestedURL }

        let directory = requestedURL.deletingLastPathComponent()
        let ext = requestedURL.pathExtension
        let stem = requestedURL.deletingPathExtension().lastPathComponent
        var counter = 2

        while true {
            let filename = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}

/// Enough to notice that a file was edited or replaced since it was read:
/// inode, size and modification date.
struct FileFingerprint: Equatable, Sendable {
    let fileNumber: UInt64
    let size: UInt64
    let modificationDate: Date

    init?(url: URL, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        self.fileNumber = number
        self.size = size
        self.modificationDate = date
    }
}
