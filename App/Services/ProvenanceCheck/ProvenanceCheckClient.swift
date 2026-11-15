import Foundation

/// One signal OpenAI's provenance check reported for an image.
struct ProvenanceSignal: Equatable, Sendable {
    enum Kind: String, Sendable {
        case synthID = "synthid"
        case c2pa
    }

    let kind: Kind
    let detected: Bool
    /// C2PA only: "trusted", "valid", "invalid" or "not_present".
    let validationState: String?
    let issuer: String?
    let model: String?
    let generatedAt: String?
}

/// OpenAI's answer for one image. It covers OpenAI's own signals only.
struct ProvenanceCheckResult: Equatable, Sendable {
    let signals: [ProvenanceSignal]

    var synthID: ProvenanceSignal? { signals.first { $0.kind == .synthID } }
    var c2pa: ProvenanceSignal? { signals.first { $0.kind == .c2pa } }
    var detectedAny: Bool { signals.contains(where: \.detected) }
}

enum ProvenanceCheckError: LocalizedError, Equatable {
    case missingKey
    case badKey
    case noAccess
    case noCredit
    case rateLimited
    case overloaded
    case unsupportedType
    case tooLarge
    case unreadableFile(String)
    case unreadableResponse
    case rejected(status: Int, message: String)
    case network(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "There's no saved OpenAI API key. Add one in Settings, under AI review.")
        case .badKey: String(localized: "OpenAI rejected this API key. Check it in Settings, under AI review.")
        case .noAccess: String(localized: "This OpenAI organization doesn't have access to the provenance check yet (HTTP 404).")
        case .noCredit: String(localized: "This account has no credit or has reached a spending limit.")
        case .rateLimited: String(localized: "OpenAI's rate limit for the provenance check was reached. Try again later.")
        case .overloaded: String(localized: "OpenAI is overloaded right now. Try again later.")
        case .unsupportedType: String(localized: "The online check takes PNG, JPEG, WebP and GIF images only.")
        case .tooLarge: String(localized: "This image is larger than 50 MB, the most the online check accepts.")
        case let .unreadableFile(message): String(localized: "The image couldn't be read: \(message)")
        case .unreadableResponse: String(localized: "OpenAI's answer wasn't in the expected form, so it was ignored.")
        case let .rejected(status, message):
            message.isEmpty ? String(localized: "OpenAI refused the request (HTTP \(status)).") : String(localized: "OpenAI refused the request (HTTP \(status)): \(message)")
        case let .network(message): String(localized: "OpenAI couldn't be reached: \(message)")
        case .timedOut: String(localized: "OpenAI took too long to answer.")
        }
    }
}

protocol ProvenanceChecking: Sendable {
    func check(imageData: Data, fileExtension: String, apiKey: String) async throws -> ProvenanceCheckResult
}

/// OpenAI's content provenance check: is there an OpenAI SynthID watermark or
/// OpenAI-issued Content Credentials in this image? One upload per request.
struct OpenAIProvenanceClient: ProvenanceChecking {
    static let endpoint = URL(string: "https://api.openai.com/v1/content_provenance_checks")!
    static let maximumBytes = 50 * 1024 * 1024
    private static let longestRetryWait = 60.0

    static let mediaTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif",
    ]

    static func supports(_ url: URL) -> Bool {
        mediaTypes[url.pathExtension.lowercased()] != nil
    }

    /// Shares the AI review's session: ephemeral, and it refuses redirects so
    /// the key only ever goes to OpenAI.
    var session: URLSession = AIReviewClient.session
    var wait: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    func check(imageData: Data, fileExtension: String, apiKey: String) async throws -> ProvenanceCheckResult {
        guard let mediaType = Self.mediaTypes[fileExtension.lowercased()] else { throw ProvenanceCheckError.unsupportedType }
        guard imageData.count <= Self.maximumBytes else { throw ProvenanceCheckError.tooLarge }
        let request = Self.urlRequest(
            imageData: imageData, fileExtension: fileExtension.lowercased(), mediaType: mediaType, apiKey: apiKey
        )
        return try Self.result(from: try await perform(request, apiKey: apiKey))
    }

    private func perform(_ request: URLRequest, apiKey: String) async throws -> Data {
        var retried = false
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw error.code == .timedOut ? ProvenanceCheckError.timedOut : ProvenanceCheckError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw ProvenanceCheckError.unreadableResponse }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw ProvenanceCheckError.badKey
            case 402:
                throw ProvenanceCheckError.noCredit
            case 404:
                throw ProvenanceCheckError.noAccess
            case 429:
                // OpenAI says to honour Retry-After; one short wait at most.
                let delay = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 5
                guard !retried, delay <= Self.longestRetryWait else { throw ProvenanceCheckError.rateLimited }
                retried = true
                try await wait(delay)
            case 500...:
                guard !retried else { throw ProvenanceCheckError.overloaded }
                retried = true
                try await wait(2)
            default:
                throw ProvenanceCheckError.rejected(status: http.statusCode, message: Self.errorMessage(in: data, apiKey: apiKey))
            }
        }
    }

    // MARK: Request

    /// A multipart upload with one `file` part. The file name is neutral, so the
    /// user's own file name never leaves the Mac.
    static func urlRequest(
        imageData: Data,
        fileExtension: String,
        mediaType: String,
        apiKey: String,
        boundary: String = "ProvenanceCleaner-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"image.\(fileExtension)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mediaType)\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    // MARK: Response

    /// Reads `results`. Entries of an unknown type are skipped; an entry of a
    /// known type without a readable outcome makes the whole answer unreadable.
    static func result(from data: Data) throws -> ProvenanceCheckResult {
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data),
              response["object"]?.stringValue == "content_provenance_check",
              let results = response["results"]?.arrayValue
        else {
            throw ProvenanceCheckError.unreadableResponse
        }
        var signals: [ProvenanceSignal] = []
        for item in results {
            guard let kind = item["type"]?.stringValue.flatMap(ProvenanceSignal.Kind.init(rawValue:)) else { continue }
            let detected: Bool
            switch item["outcome"]?.stringValue {
            case "detected": detected = true
            case "not_detected": detected = false
            default: throw ProvenanceCheckError.unreadableResponse
            }
            guard !signals.contains(where: { $0.kind == kind }) else { continue }
            signals.append(ProvenanceSignal(
                kind: kind,
                detected: detected,
                validationState: item["validation_state"]?.stringValue,
                issuer: item["issuer"]?.stringValue.map { String($0.prefix(200)) },
                model: item["model"]?.stringValue.map { String($0.prefix(100)) },
                generatedAt: item["generated_at"]?.stringValue.map { String($0.prefix(64)) }
            ))
        }
        return ProvenanceCheckResult(signals: signals)
    }

    private static func errorMessage(in data: Data, apiKey: String) -> String {
        let response = try? JSONDecoder().decode(JSONValue.self, from: data)
        let message = response?["error"]?["message"]?.stringValue ?? ""
        let safe = apiKey.isEmpty ? message : message.replacingOccurrences(of: apiKey, with: "[key]")
        return String(safe.prefix(240))
    }
}
