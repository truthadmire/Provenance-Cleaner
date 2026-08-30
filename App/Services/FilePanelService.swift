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

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
