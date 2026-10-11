import Foundation

let helperURL = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Helpers/ProvenanceEngine.app/Contents/MacOS/provenance-engine")
let process = Process()
let input = Pipe()
let output = Pipe()

process.executableURL = helperURL
process.standardInput = input
process.standardOutput = output
process.standardError = FileHandle.standardError

var environment = ProcessInfo.processInfo.environment
for key in environment.keys where
    key.hasPrefix("DYLD_") ||
    key == "PYTHONHOME" ||
    key == "PYTHONPATH" ||
    key.hasPrefix("PROVENANCE_REMOTE_") ||
    key.hasPrefix("PROVENANCE_MODEL_") {
    environment.removeValue(forKey: key)
}
process.environment = environment

func exchange(_ request: [String: Any]) throws -> (Data, [String: Any]) {
    var requestData = try JSONSerialization.data(withJSONObject: request, options: .sortedKeys)
    requestData.append(0x0A)
    try input.fileHandleForWriting.write(contentsOf: requestData)
    var line = Data()
    while line.count < (16 << 20) {
        guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
            throw NSError(domain: "ReleaseProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper closed stdout"])
        }
        if byte[byte.startIndex] == 0x0A {
            guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any], response["ok"] as? Bool == true else {
                throw NSError(domain: "ReleaseProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "helper request failed: \(String(decoding: line, as: UTF8.self))"])
            }
            line.append(0x0A)
            return (line, response)
        }
        line.append(byte)
    }
    throw NSError(domain: "ReleaseProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "helper response too large"])
}

do {
    try process.run()
    let (capabilities, _) = try exchange(["requestID": "signed-release-probe", "operation": "capabilities"])
    if CommandLine.arguments.contains("--pdf-smoke") {
        let fixture = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/embedded-provenance.pdf")
        let sourceData = try Data(contentsOf: fixture)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PDFProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = staging.appendingPathComponent("input.pdf")
        let cleaned = staging.appendingPathComponent("output.pdf")
        try sourceData.write(to: source)
        let (_, response) = try exchange([
            "requestID": "pdf-smoke", "operation": "clean",
            "inputPath": source.path, "outputPath": cleaned.path,
            "options": ["deepImages": "auto"],
        ])
        let report = response["report"] as? [String: Any]
        let meta = report?["meta"] as? [String: Any]
        let cleanedData = try Data(contentsOf: cleaned)
        guard meta?["deep_image_pass"] as? Bool == true,
              report?["pdf_deep_clean_incomplete"] as? Bool == false,
              cleanedData.starts(with: Data("%PDF".utf8)),
              cleanedData.range(of: Data("contentauth".utf8)) == nil,
              try Data(contentsOf: source) == sourceData else {
            throw NSError(domain: "ReleaseProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "sandboxed PDF deep-clean smoke failed: \(response)"])
        }
        FileHandle.standardError.write(Data("sandboxed PDF deep-clean smoke passed\n".utf8))
    }
    if CommandLine.arguments.contains("--word-smoke") {
        let fixture = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/editing-traces.docx")
        let sourceData = try Data(contentsOf: fixture)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("WordProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = staging.appendingPathComponent("input.docx")
        let cleaned = staging.appendingPathComponent("output.docx")
        try sourceData.write(to: source)
        let (_, response) = try exchange([
            "requestID": "word-smoke", "operation": "clean",
            "inputPath": source.path, "outputPath": cleaned.path,
            "options": ["wordTraces": ["rsids": "remove", "dates": "remove"]],
        ])
        let report = response["report"] as? [String: Any]
        let changes = report?["word_trace_changes"] as? [String: Any]
        let (_, inspection) = try exchange([
            "requestID": "word-smoke-inspect", "operation": "inspect", "inputPath": cleaned.path,
        ])
        let afterReport = inspection["report"] as? [String: Any]
        let traces = afterReport?["word_editing_traces"] as? [String: Any]
        guard (changes?["changedFields"] as? Int ?? 0) > 0,
              traces?["available"] as? Bool == true,
              traces?["sessionIDs"] as? Int == 0,
              traces?["annotationDates"] as? Int == 0,
              traces?["documentDates"] as? Int == 0,
              try Data(contentsOf: source) == sourceData else {
            throw NSError(domain: "ReleaseProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: "sandboxed Word editing-trace smoke failed"])
        }
        FileHandle.standardError.write(Data("sandboxed Word editing-trace smoke passed\n".utf8))
    }
    if CommandLine.arguments.contains("--metadata-smoke") {
        for name in ["editing-traces.docx", "embedded-provenance.pdf"] {
            let fixture = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + name)
            let sourceData = try Data(contentsOf: fixture)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataProbe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let source = staging.appendingPathComponent(name)
            let edited = staging.appendingPathComponent("edited." + fixture.pathExtension)
            try sourceData.write(to: source)
            _ = try exchange([
                "requestID": "metadata-smoke", "operation": "clean",
                "inputPath": source.path, "outputPath": edited.path,
                "options": ["metadataEdits": ["author": "Release smoke 陈", "title": "Verified copy"]],
            ])
            let (_, inspection) = try exchange([
                "requestID": "metadata-smoke-inspect", "operation": "inspect", "inputPath": edited.path,
            ])
            let report = inspection["report"] as? [String: Any]
            let metadata = report?["metadata"] as? [String: Any]
            let fields = metadata?["fields"] as? [[String: Any]] ?? []
            guard fields.first(where: { $0["id"] as? String == "author" })?["value"] as? String == "Release smoke 陈",
                  try Data(contentsOf: source) == sourceData else {
                throw NSError(domain: "ReleaseProbe", code: 6, userInfo: [NSLocalizedDescriptionKey: "sandboxed metadata edit/read-back failed for \(name)"])
            }
        }
        FileHandle.standardError.write(Data("sandboxed metadata edit/read-back smoke passed\n".utf8))
    }
    if CommandLine.arguments.contains("--c2pa-smoke") {
        let fixture = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/signed-c2pa.jpg")
        let (_, inspection) = try exchange([
            "requestID": "c2pa-smoke", "operation": "inspect", "inputPath": fixture.path,
        ])
        let report = inspection["report"] as? [String: Any]
        let c2pa = report?["c2pa"] as? [String: Any]
        let certificates = c2pa?["certificates"] as? [[String: Any]] ?? []
        guard c2pa?["signature"] as? String == "valid",
              c2pa?["contentBinding"] as? String == "valid",
              c2pa?["trust"] as? String == "untrusted",
              c2pa?["inspectionIncomplete"] as? Bool == false,
              certificates.count == 2,
              !(certificates[0]["sha256"] as? String ?? "").isEmpty else {
            throw NSError(domain: "ReleaseProbe", code: 7, userInfo: [NSLocalizedDescriptionKey: "sandboxed C2PA certificate-chain smoke failed: \(String(describing: c2pa))"])
        }
        FileHandle.standardError.write(Data("sandboxed C2PA certificate-chain smoke passed\n".utf8))
    }
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    FileHandle.standardOutput.write(capabilities)
    exit(process.terminationStatus)
} catch {
    if process.isRunning { process.terminate() }
    FileHandle.standardError.write(Data("release probe failed: \(error)\n".utf8))
    exit(1)
}
