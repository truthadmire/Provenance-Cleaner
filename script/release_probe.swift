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

do {
    try process.run()
    input.fileHandleForWriting.write(
        Data("{\"requestID\":\"signed-release-probe\",\"operation\":\"capabilities\"}\n".utf8)
    )
    try input.fileHandleForWriting.close()
    let response = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    FileHandle.standardOutput.write(response)
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("release probe failed: \(error)\n".utf8))
    exit(1)
}
