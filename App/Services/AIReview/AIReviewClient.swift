import Foundation

struct AIReviewRequest: Sendable {
    let provider: AIProvider
    let endpoint: AIEndpoint
    let model: String
    let apiKey: String
    let reviewText: String
    let offlineSummary: String
    /// Messages the offline checks decoded. A finding may quote these too.
    var decodedMessages: [String] = []
}

struct AIReviewFinding: Equatable, Identifiable, Sendable {
    let id: Int
    let technique: String
    let severity: PromptInjectionScan.Severity
    let quote: String
    let explanation: String
}

struct AIReviewOutcome: Equatable, Sendable {
    let verdict: PromptInjectionScan.Verdict
    let findings: [AIReviewFinding]
    /// Claims dropped because the text they quoted isn't in the file.
    let removedClaims: Int
}

enum AIReviewError: LocalizedError, Equatable {
    case missingKey
    case badKey
    case noCredit
    case rateLimited
    case overloaded
    case declined
    case truncated
    case unreadableResponse
    case tooLong
    case rejected(status: Int, message: String)
    case network(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingKey: "There's no saved API key for this provider."
        case .badKey: "The provider rejected this API key. Check the key, and for GLM and Qwen its region, in Settings."
        case .noCredit: "This account has no credit or has reached a spending limit."
        case .rateLimited: "The provider's rate limit was reached. Try again in a moment."
        case .overloaded: "The provider is overloaded right now. Try again later."
        case .declined: "The provider declined to review this text, so it gives no verdict."
        case .truncated: "The provider's answer was cut off before it finished."
        case .unreadableResponse: "The provider's answer wasn't in the expected form, so it was ignored."
        case .tooLong: "This text is too long for the selected model."
        case let .rejected(status, message):
            message.isEmpty ? "The provider refused the request (HTTP \(status))." : "The provider refused the request (HTTP \(status)): \(message)"
        case let .network(message): "The provider couldn't be reached: \(message)"
        case .timedOut: "The provider took too long to answer."
        }
    }
}

protocol AIReviewing: Sendable {
    func review(_ request: AIReviewRequest) async throws -> AIReviewOutcome
}

/// Refuses redirects so an API key can only ever go to the address it was meant for.
final class AIReviewSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

struct AIReviewClient: AIReviewing {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: AIReviewSessionDelegate(), delegateQueue: nil)
    }()

    private static let tokenBudget = 8_000
    private static let longestRetryWait = 60.0
    private static let maximumFindings = 100

    var session: URLSession = AIReviewClient.session
    var wait: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    func review(_ request: AIReviewRequest) async throws -> AIReviewOutcome {
        let chunks = AIReviewPrompt.chunks(of: request.reviewText)
        var claims: [Claim] = []
        for (index, chunk) in chunks.enumerated() {
            let user = AIReviewPrompt.user(
                document: chunk,
                offlineSummary: request.offlineSummary,
                part: index + 1,
                of: chunks.count,
                code: AIReviewPrompt.newCode()
            )
            claims += try await answer(to: user, request: request)
        }
        let evidence = ([request.reviewText] + request.decodedMessages).joined(separator: "\n")
        return Self.outcome(from: claims, reviewText: evidence)
    }

    /// Asks once, with room to spare if the first answer is cut off and a plainer
    /// format if the model refuses a schema.
    private func answer(to user: String, request: AIReviewRequest) async throws -> [Claim] {
        var budget = Self.tokenBudget
        var useSchema = true
        while true {
            let urlRequest = try Self.urlRequest(for: request, user: user, maximumTokens: budget, useSchema: useSchema)
            do {
                let data = try await perform(urlRequest, apiKey: request.apiKey)
                return try Self.claims(in: try Self.answerText(in: data, api: request.provider.api))
            } catch AIReviewError.truncated where budget == Self.tokenBudget {
                budget *= 2
            } catch let AIReviewError.rejected(status, _) where status == 400 && useSchema && request.provider.api == .chatCompletions(format: .jsonSchema, tokenLimitKey: "max_tokens") {
                useSchema = false
            }
        }
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
                throw error.code == .timedOut ? AIReviewError.timedOut : AIReviewError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw AIReviewError.unreadableResponse }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw AIReviewError.badKey
            case 402:
                throw AIReviewError.noCredit
            case 429:
                let delay = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 5
                guard !retried, delay <= Self.longestRetryWait else { throw AIReviewError.rateLimited }
                retried = true
                try await wait(delay)
            case 500...:
                guard !retried else { throw AIReviewError.overloaded }
                retried = true
                try await wait(2)
            default:
                throw AIReviewError.rejected(status: http.statusCode, message: Self.errorMessage(in: data, apiKey: apiKey))
            }
        }
    }

    // MARK: Requests

    static func urlRequest(for request: AIReviewRequest, user: String, maximumTokens: Int, useSchema: Bool = true) throws -> URLRequest {
        var urlRequest = URLRequest(url: request.endpoint.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: JSONValue] = ["model": .string(request.model)]
        let tokens = JSONValue.number(Double(maximumTokens))
        switch request.provider.api {
        case .anthropicMessages:
            urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = tokens
            body["system"] = .string(AIReviewPrompt.system)
            body["messages"] = .array([.object(["role": .string("user"), "content": .string(user)])])
            body["output_config"] = .object([
                "effort": .string("low"),
                "format": .object(["type": .string("json_schema"), "schema": AIReviewPrompt.schema]),
            ])
            // A file quoting attacks can trip a safety classifier; let the API
            // re-run such a request on its chosen model. Haiku has no fallback.
            if !request.model.contains("haiku") {
                urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = .string("default")
            }
        case .openAIResponses:
            urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
            body["max_output_tokens"] = tokens
            body["instructions"] = .string(AIReviewPrompt.system)
            body["input"] = .string(user)
            body["text"] = .object(["format": .object([
                "type": .string("json_schema"),
                "name": .string("prompt_injection_review"),
                "strict": .bool(true),
                "schema": AIReviewPrompt.schema,
            ])])
        case let .chatCompletions(format, tokenLimitKey):
            urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
            if let tokenLimitKey {
                body[tokenLimitKey] = tokens
            }
            body["messages"] = .array([
                .object(["role": .string("system"), "content": .string(AIReviewPrompt.system)]),
                .object(["role": .string("user"), "content": .string(user)]),
            ])
            if format == .jsonSchema, useSchema {
                body["response_format"] = .object([
                    "type": .string("json_schema"),
                    "json_schema": .object([
                        "name": .string("prompt_injection_review"),
                        "strict": .bool(true),
                        "schema": AIReviewPrompt.schema,
                    ]),
                ])
            } else {
                body["response_format"] = .object(["type": .string("json_object")])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        urlRequest.httpBody = try encoder.encode(JSONValue.object(body))
        return urlRequest
    }

    // MARK: Responses

    /// The model's reply text, once the response says it's complete.
    static func answerText(in data: Data, api: AIProviderAPI) throws -> String {
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AIReviewError.unreadableResponse
        }
        let text: String
        switch api {
        case .anthropicMessages:
            switch response["stop_reason"]?.stringValue {
            case "refusal": throw AIReviewError.declined
            case "max_tokens": throw AIReviewError.truncated
            default: break
            }
            text = (response["content"]?.arrayValue ?? [])
                .filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }
                .joined()
        case .openAIResponses:
            if response["status"]?.stringValue == "incomplete" {
                throw response["incomplete_details"]?["reason"]?.stringValue == "content_filter" ? AIReviewError.declined : .truncated
            }
            let parts = (response["output"]?.arrayValue ?? [])
                .filter { $0["type"]?.stringValue == "message" }
                .flatMap { $0["content"]?.arrayValue ?? [] }
            if parts.contains(where: { $0["type"]?.stringValue == "refusal" }) {
                throw AIReviewError.declined
            }
            text = parts.filter { $0["type"]?.stringValue == "output_text" }
                .compactMap { $0["text"]?.stringValue }
                .joined()
        case .chatCompletions:
            let choice = response["choices"]?.arrayValue?.first
            switch choice?["finish_reason"]?.stringValue {
            case "length": throw AIReviewError.truncated
            case "content_filter", "sensitive": throw AIReviewError.declined
            case "model_context_window_exceeded": throw AIReviewError.tooLong
            case "insufficient_system_resource": throw AIReviewError.overloaded
            case "network_error": throw AIReviewError.network("the provider reported a network error")
            default: break
            }
            if choice?["message"]?["refusal"]?.stringValue?.isEmpty == false {
                throw AIReviewError.declined
            }
            text = choice?["message"]?["content"]?.stringValue ?? ""
        }
        return text
    }

    struct Claim: Equatable {
        let technique: String
        let severity: PromptInjectionScan.Severity
        let quote: String
        let explanation: String
    }

    /// The claims in a reply. Anything but the agreed shape is refused, whatever it says.
    static func claims(in text: String) throws -> [Claim] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(text[start...end].utf8)),
              reply["verdict"]?.stringValue.flatMap(PromptInjectionScan.Verdict.init(rawValue:)) != nil,
              let findings = reply["findings"]?.arrayValue
        else {
            throw AIReviewError.unreadableResponse
        }
        return try findings.map { item in
            guard let technique = item["technique"]?.stringValue,
                  let severity = item["severity"]?.stringValue.flatMap(PromptInjectionScan.Severity.init(rawValue:)),
                  let quote = item["quote"]?.stringValue,
                  let explanation = item["explanation"]?.stringValue
            else {
                throw AIReviewError.unreadableResponse
            }
            return Claim(technique: technique, severity: severity, quote: quote, explanation: explanation)
        }
    }

    /// Keeps only claims that quote the file, and takes the verdict from those. A
    /// document that talks the model into a verdict still has to show its evidence.
    static func outcome(from claims: [Claim], reviewText: String) -> AIReviewOutcome {
        let document = normalized(reviewText)
        var seen = Set<String>()
        var kept: [AIReviewFinding] = []
        var removed = 0
        for claim in claims {
            let quote = normalized(claim.quote)
            guard !quote.isEmpty, document.contains(quote) else {
                removed += 1
                continue
            }
            guard seen.insert(quote).inserted, kept.count < maximumFindings else { continue }
            kept.append(AIReviewFinding(
                id: kept.count,
                technique: String(claim.technique.prefix(60)),
                severity: claim.severity,
                quote: String(claim.quote.prefix(400)),
                explanation: String(claim.explanation.prefix(400))
            ))
        }
        let verdict: PromptInjectionScan.Verdict = kept.contains { $0.severity == .high } ? .likely
            : kept.contains { $0.severity == .medium } ? .suspicious : .none
        return AIReviewOutcome(verdict: verdict, findings: kept, removedClaims: removed)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func errorMessage(in data: Data, apiKey: String) -> String {
        let response = try? JSONDecoder().decode(JSONValue.self, from: data)
        let message = response?["error"]?["message"]?.stringValue ?? response?["message"]?.stringValue ?? ""
        let safe = apiKey.isEmpty ? message : message.replacingOccurrences(of: apiKey, with: "[key]")
        return String(safe.prefix(240))
    }
}
