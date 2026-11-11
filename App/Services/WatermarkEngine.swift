import Foundation

protocol WatermarkEngine: Sendable {
    func capabilities() async throws -> EngineCapabilities
    func inspect(_ input: EngineInput) async throws -> InspectionResult
    func clean(_ input: EngineInput, options: CleanOptions) async throws -> CleanResult
    func scan(_ input: EngineInput) async throws -> PromptInjectionScan
    func cancel(requestID: UUID) async
}

extension WatermarkEngine {
    func capabilities(requestID: UUID) async throws -> EngineCapabilities {
        try await capabilities()
    }

    func inspect(fileAt inputURL: URL, requestID: UUID = UUID()) async throws -> EngineInspection {
        try await inspect(EngineInput(requestID: requestID, inputURL: inputURL))
    }

    func scan(fileAt inputURL: URL, requestID: UUID = UUID()) async throws -> PromptInjectionScan {
        try await scan(EngineInput(requestID: requestID, inputURL: inputURL))
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
            String(localized: "The bundled cleaning engine was not found at \(path).")
        case let .helperLaunchFailed(message):
            String(localized: "The cleaning engine could not start: \(message)")
        case let .helperFailed(message):
            String(localized: "The cleaning engine reported an error: \(EngineText.localized(message))")
        case let .invalidResponse(message):
            String(localized: "The cleaning engine returned an invalid response: \(message)")
        case let .invalidInput(message):
            message
        case let .inputTooLarge(actualBytes, maximumBytes):
            String(localized: "The selected file is \(ByteCountFormatter.string(fromByteCount: actualBytes, countStyle: .file)); the per-file limit is \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)).")
        case .mismatchedResponse:
            String(localized: "The cleaning engine response did not match the request.")
        case let .missingOutput(url):
            String(localized: "The cleaning engine did not create the expected output at \(url.path).")
        case .cancelled:
            String(localized: "The cleaning operation was cancelled.")
        }
    }
}
