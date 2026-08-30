import Foundation

protocol WatermarkEngine: Sendable {
    func capabilities() async throws -> EngineCapabilities
    func inspect(_ input: EngineInput) async throws -> InspectionResult
    func clean(_ input: EngineInput, options: CleanOptions) async throws -> CleanResult
    func cancel(requestID: UUID) async
}

extension WatermarkEngine {
    func capabilities(requestID: UUID) async throws -> EngineCapabilities {
        try await capabilities()
    }

    func inspect(fileAt inputURL: URL, requestID: UUID = UUID()) async throws -> EngineInspection {
        try await inspect(EngineInput(requestID: requestID, inputURL: inputURL))
    }

    func clean(
        fileAt inputURL: URL,
        outputURL: URL,
        options: CleaningOptions,
        requestID: UUID = UUID()
    ) async throws -> EngineCleanResult {
        try await clean(
            EngineInput(requestID: requestID, inputURL: inputURL, outputURL: outputURL),
            options: options
        )
    }
}

enum WatermarkEngineError: LocalizedError, Equatable, Sendable {
    case helperNotFound(String)
    case helperLaunchFailed(String)
    case helperFailed(String)
    case invalidResponse(String)
    case invalidInput(String)
    case inputTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case mismatchedResponse
    case missingOutput(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .helperNotFound(path):
            "The bundled cleaning engine was not found at \(path)."
        case let .helperLaunchFailed(message):
            "The cleaning engine could not start: \(message)"
        case let .helperFailed(message):
            "The cleaning engine reported an error: \(message)"
        case let .invalidResponse(message):
            "The cleaning engine returned an invalid response: \(message)"
        case let .invalidInput(message):
            message
        case let .inputTooLarge(actualBytes, maximumBytes):
            "The selected file is \(ByteCountFormatter.string(fromByteCount: actualBytes, countStyle: .file)); the per-file limit is \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file))."
        case .mismatchedResponse:
            "The cleaning engine response did not match the request."
        case let .missingOutput(url):
            "The cleaning engine did not create the expected output at \(url.path)."
        case .cancelled:
            "The cleaning operation was cancelled."
        }
    }
}
