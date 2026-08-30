import Foundation

enum SupportedFileTypes {
    static let textExtensions: Set<String> = [
        "txt", "text", "css", "js", "py", "rs", "go", "json", "yaml", "yml", "toml", "csv",
    ]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "avif", "heic", "heif", "bmp", "gif", "tiff", "tif",
    ]

    static let containerExtensions: Set<String> = [
        "svg", "pdf", "docx", "xlsx", "pptx", "odt", "epub", "html", "htm", "md", "markdown", "mdx",
    ]

    static let audioVideoExtensions: Set<String> = [
        "mp4", "mov", "m4a", "m4v", "wav", "mp3", "flac",
    ]

    static let allExtensions = textExtensions
        .union(imageExtensions)
        .union(containerExtensions)
        .union(audioVideoExtensions)

    static func kind(for url: URL) -> WatermarkKind {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        if containerExtensions.contains(ext) { return .container }
        if audioVideoExtensions.contains(ext) { return .av }
        return .unknown
    }

    static func isSupported(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    static func expandInputURLs(_ inputURLs: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        return inputURLs.filter { url in
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                return false
            }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    static func cleanedFilename(for sourceURL: URL) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        return ext.isEmpty ? "\(stem).cleaned" : "\(stem).cleaned.\(ext)"
    }
}
