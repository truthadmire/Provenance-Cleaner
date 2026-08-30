import Foundation

actor BundledWatermarkEngine: WatermarkEngine {
    static let helperOverrideEnvironmentKey = "PROVENANCE_CLEANER_HELPER_PATH"
    static let relativeBundledHelperPath = "Contents/Helpers/ProvenanceEngine.app/Contents/MacOS/provenance-engine"
    static let maximumInputBytes: Int64 = 256 << 20

    private let explicitHelperURL: URL?
    private let bundleURL: URL
    private let environment: [String: String]
    private var session: HelperProcessSession?

    init(
        helperURL: URL? = nil,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.explicitHelperURL = helperURL
        self.bundleURL = bundleURL
        self.environment = environment
    }

    func capabilities() async throws -> EngineCapabilities {
        try await capabilities(requestID: UUID())
    }

    func capabilities(requestID: UUID) async throws -> EngineCapabilities {
        let response = try await send(
            HelperRequest(requestID: requestID.uuidString, operation: .capabilities)
        )
        return EngineCapabilities(report: WatermarkReport(raw: response.report))
    }

    func inspect(_ input: EngineInput) async throws -> InspectionResult {
        let staging = try EngineStagingArea(
            requestID: input.requestID,
            sourceURL: input.inputURL,
            maximumInputBytes: Self.maximumInputBytes
        )
        defer { staging.remove() }

        let response = try await send(
            HelperRequest(
                requestID: input.requestID.uuidString,
                operation: .inspect,
                inputPath: staging.inputURL.path
            )
        )
        return EngineInspection(
            kind: response.watermarkKind,
            report: WatermarkReport(raw: response.report)
        )
    }

    func clean(_ input: EngineInput, options: CleanOptions) async throws -> CleanResult {
        guard let requestedOutputURL = input.outputURL else {
            throw WatermarkEngineError.invalidInput("A clean request requires an output URL.")
        }
        let staging = try EngineStagingArea(
            requestID: input.requestID,
            sourceURL: input.inputURL,
            maximumInputBytes: Self.maximumInputBytes
        )
        defer { staging.remove() }

        let response = try await send(
            HelperRequest(
                requestID: input.requestID.uuidString,
                operation: .clean,
                inputPath: staging.inputURL.path,
                outputPath: staging.outputURL.path,
                options: options
            )
        )

        guard let outputPath = response.outputPath else {
            throw WatermarkEngineError.invalidResponse("A successful clean response omitted outputPath.")
        }
        let helperOutputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard helperOutputURL.path == staging.outputURL.standardizedFileURL.path else {
            throw WatermarkEngineError.invalidResponse("The helper returned an unexpected output path.")
        }
        try staging.publishOutput(to: requestedOutputURL)

        return EngineCleanResult(
            kind: response.watermarkKind,
            outputURL: requestedOutputURL,
            report: WatermarkReport(raw: response.report)
        )
    }

    func cancel(requestID: UUID) async {
        session?.cancel(requestID: requestID)
    }

    func resolvedHelperURL() throws -> URL {
        if let explicitHelperURL {
            return explicitHelperURL
        }
        if let override = environment[Self.helperOverrideEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let bundled = bundleURL.appendingPathComponent(Self.relativeBundledHelperPath)
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw WatermarkEngineError.helperNotFound(bundled.path)
        }
        return bundled
    }

    private func send(_ request: HelperRequest) async throws -> HelperResponse {
        let requestID = UUID(uuidString: request.requestID) ?? UUID()
        let activeSession: HelperProcessSession
        if let session {
            activeSession = session
        } else {
            let created = HelperProcessSession(
                helperURL: try resolvedHelperURL(),
                parentEnvironment: environment
            )
            session = created
            activeSession = created
        }

        let response = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try activeSession.exchange(request, requestID: requestID)
            }.value
        } onCancel: {
            activeSession.cancel(requestID: requestID)
        }
        try Task.checkCancellation()

        guard response.requestID == request.requestID else {
            throw WatermarkEngineError.mismatchedResponse
        }
        guard response.ok else {
            throw WatermarkEngineError.helperFailed(response.error ?? "Unknown helper error")
        }
        return response
    }
}

private final class HelperProcessSession: @unchecked Sendable {
    private static let maximumResponseBytes = 16 << 20
    private let helperURL: URL
    private let parentEnvironment: [String: String]
    private let requestGate = NSLock()
    private let stateLock = NSLock()
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var activeRequestID: UUID?
    private var cancelledRequestIDs: Set<UUID> = []

    init(helperURL: URL, parentEnvironment: [String: String]) {
        self.helperURL = helperURL
        self.parentEnvironment = parentEnvironment
    }

    deinit {
        shutdown()
    }

    func exchange(_ request: HelperRequest, requestID: UUID) throws -> HelperResponse {
        requestGate.lock()
        defer { requestGate.unlock() }

        let handles: (input: FileHandle, output: FileHandle)
        stateLock.lock()
        do {
            handles = try ensureProcessLocked()
            activeRequestID = requestID
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }

        defer {
            stateLock.lock()
            if activeRequestID == requestID { activeRequestID = nil }
            cancelledRequestIDs.remove(requestID)
            stateLock.unlock()
        }

        do {
            var encoded = try JSONEncoder().encode(request)
            encoded.append(0x0A)
            try handles.input.write(contentsOf: encoded)
            let responseData = try Self.readLine(from: handles.output)
            guard !responseData.isEmpty else {
                throw WatermarkEngineError.invalidResponse("The helper closed stdout before responding.")
            }
            return try JSONDecoder().decode(HelperResponse.self, from: responseData)
        } catch {
            stateLock.lock()
            let wasCancelled = cancelledRequestIDs.contains(requestID)
            invalidateProcessLocked(terminate: true)
            stateLock.unlock()
            if wasCancelled || error is CancellationError {
                throw WatermarkEngineError.cancelled
            }
            if let engineError = error as? WatermarkEngineError {
                throw engineError
            }
            throw WatermarkEngineError.invalidResponse(error.localizedDescription)
        }
    }

    func cancel(requestID: UUID) {
        stateLock.lock()
        guard activeRequestID == requestID else {
            stateLock.unlock()
            return
        }
        cancelledRequestIDs.insert(requestID)
        invalidateProcessLocked(terminate: true)
        stateLock.unlock()
    }

    private func shutdown() {
        stateLock.lock()
        invalidateProcessLocked(terminate: true)
        stateLock.unlock()
    }

    private func ensureProcessLocked() throws -> (input: FileHandle, output: FileHandle) {
        if let process, process.isRunning, let standardInput, let standardOutput {
            return (standardInput, standardOutput)
        }
        invalidateProcessLocked(terminate: false)

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw WatermarkEngineError.helperNotFound(helperURL.path)
        }

        let created = Process()
        if helperURL.pathExtension.lowercased() == "py" {
            created.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            created.arguments = ["python3", helperURL.path]
        } else {
            created.executableURL = helperURL
        }
        created.environment = Self.offlineEnvironment(from: parentEnvironment)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        created.standardInput = inputPipe
        created.standardOutput = outputPipe
        created.standardError = FileHandle.nullDevice

        do {
            try created.run()
        } catch {
            throw WatermarkEngineError.helperLaunchFailed(error.localizedDescription)
        }

        process = created
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        return (inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading)
    }

    private func invalidateProcessLocked(terminate: Bool) {
        let invalidatedProcess = process
        let invalidatedInput = standardInput
        let invalidatedOutput = standardOutput
        process = nil
        standardInput = nil
        standardOutput = nil

        try? invalidatedInput?.close()
        if terminate, invalidatedProcess?.isRunning == true {
            invalidatedProcess?.terminate()
        }
        try? invalidatedOutput?.close()
    }

    private static func readLine(from handle: FileHandle) throws -> Data {
        var line = Data()
        while line.count <= maximumResponseBytes {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { return line }
            if byte[byte.startIndex] == 0x0A { return line }
            line.append(byte)
        }
        throw WatermarkEngineError.invalidResponse("The helper response exceeded 16 MiB.")
    }

    private static func offlineEnvironment(from source: [String: String]) -> [String: String] {
        let explicitKeys: Set<String> = [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_API_KEY", "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN", "MARKLLM_DIR", "MARKDIFFUSION_DIR",
            "REVERSE_SYNTHID_DIR", "NOAI_WATERMARK_DIR", "HTTP_PROXY", "HTTPS_PROXY",
            "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
        ]
        return source.filter { key, _ in
            !key.hasPrefix("WATERMARKS_") && !explicitKeys.contains(key)
        }
    }
}

private final class EngineStagingArea {
    let rootURL: URL
    let inputURL: URL
    let outputURL: URL
    private let fileManager: FileManager

    init(
        requestID: UUID,
        sourceURL: URL,
        maximumInputBytes: Int64,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WatermarkEngineError.invalidInput("The selected input must be a regular file.")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maximumInputBytes else {
            throw WatermarkEngineError.inputTooLarge(actualBytes: size, maximumBytes: maximumInputBytes)
        }

        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("ProvenanceCleaner", isDirectory: true)
            .appendingPathComponent("EngineJobs", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        inputURL = rootURL.appendingPathComponent(sourceURL.lastPathComponent)
        let ext = sourceURL.pathExtension
        outputURL = rootURL.appendingPathComponent(ext.isEmpty ? "result" : "result.\(ext)")

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.copyItem(at: sourceURL, to: inputURL)
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    func publishOutput(to destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw WatermarkEngineError.missingOutput(outputURL)
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: outputURL, to: temporaryURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}

enum HelperOperation: String, Codable, Sendable {
    case capabilities
    case inspect
    case clean
}

struct HelperRequest: Codable, Equatable, Sendable {
    var requestID: String
    var operation: HelperOperation
    var inputPath: String?
    var outputPath: String?
    var options: CleaningOptions?

    init(
        requestID: String = UUID().uuidString,
        operation: HelperOperation,
        inputPath: String? = nil,
        outputPath: String? = nil,
        options: CleaningOptions? = nil
    ) {
        self.requestID = requestID
        self.operation = operation
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.options = options
    }
}

struct HelperResponse: Codable, Equatable, Sendable {
    var requestID: String
    var ok: Bool
    var kind: String
    var report: JSONValue
    var outputPath: String?
    var error: String?

    var watermarkKind: WatermarkKind {
        WatermarkKind(rawValue: kind) ?? .unknown
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, ok, kind, report, outputPath, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        ok = try container.decode(Bool.self, forKey: .ok)
        kind = try container.decode(String.self, forKey: .kind)
        report = try container.decode(JSONValue.self, forKey: .report)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
        error = try container.decodeIfPresent(String.self, forKey: .error)

        guard !requestID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestID,
                in: container,
                debugDescription: "The response requires a non-empty requestID."
            )
        }
        guard !kind.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "The response requires a non-empty kind."
            )
        }
        guard report.objectValue != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .report,
                in: container,
                debugDescription: "The report envelope field must be a JSON object."
            )
        }
        if ok, error != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .error,
                in: container,
                debugDescription: "A successful response must not contain an error."
            )
        }
        if !ok, error?.isEmpty != false {
            throw DecodingError.dataCorruptedError(
                forKey: .error,
                in: container,
                debugDescription: "A failed response requires a non-empty error."
            )
        }
    }
}
