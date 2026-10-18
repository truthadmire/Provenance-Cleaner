import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanelService {
    static func chooseInputs() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose files to inspect"
        panel.prompt = "Inspect"
        panel.message = "Select files you own or are authorized to process."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.data]
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseCopyDestination(for job: CleanerJob) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save cleaned copy"
        panel.prompt = "Save Copy"
        panel.nameFieldStringValue = SupportedFileTypes.cleanedFilename(for: job.sourceURL)
        panel.directoryURL = job.sourceURL.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseBatchExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for cleaned copies"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for write access to the folder holding an original, so a `.bak`
    /// backup can be written beside it. The sandbox grants files one by one,
    /// and a backup is a new file. Returns nil unless that exact folder is chosen.
    static func requestFolderAccess(for folderURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Allow backups in this folder"
        panel.prompt = "Allow"
        panel.message = "To keep a backup beside the original, Provenance Cleaner needs permission to write in “\(folderURL.lastPathComponent)”. Choose Allow to grant it until you quit."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let chosen = panel.url,
              chosen.standardizedFileURL.path == folderURL.standardizedFileURL.path
        else { return nil }
        return chosen
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
