import Foundation

enum FileExportError: LocalizedError, Equatable, Sendable {
    case noStagedOutput
    case backupAlreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .noStagedOutput:
            "There is no cleaned output to export."
        case let .backupAlreadyExists(url):
            "A backup already exists at \(url.path). Move it elsewhere before replacing the original."
        }
    }
}

actor SafeFileExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func exportCopy(from stagedURL: URL, to requestedURL: URL) throws -> URL {
        let destination = uniqueDestination(startingAt: requestedURL)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: stagedURL, to: destination)
        return destination
    }

    func exportCopy(from stagedURL: URL, sourceURL: URL, into directoryURL: URL) throws -> URL {
        let requested = directoryURL.appendingPathComponent(
            SupportedFileTypes.cleanedFilename(for: sourceURL),
            isDirectory: false
        )
        return try exportCopy(from: stagedURL, to: requested)
    }

    func replaceOriginal(from stagedURL: URL, originalURL: URL) throws -> URL {
        let backupURL = originalURL.appendingPathExtension("bak")
        guard !fileManager.fileExists(atPath: backupURL.path) else {
            throw FileExportError.backupAlreadyExists(backupURL)
        }

        try fileManager.copyItem(at: originalURL, to: backupURL)
        let temporaryURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(originalURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try fileManager.copyItem(at: stagedURL, to: temporaryURL)
            _ = try fileManager.replaceItemAt(
                originalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
            return originalURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // Atomic replacement should leave the original in place on
            // failure. If the file system failed between rename steps,
            // restore an additional copy from the no-clobber backup while
            // retaining that backup as a second recovery path.
            if !fileManager.fileExists(atPath: originalURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.copyItem(at: backupURL, to: originalURL)
            }
            throw error
        }
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
