import Foundation

/// How a provider's API is called. Claude and OpenAI have their own request
/// shapes; the others offer an OpenAI-compatible Chat Completions endpoint.
enum AIProviderAPI: Equatable, Sendable {
    enum ResponseFormat: Equatable, Sendable {
        case jsonSchema
        case jsonObject
    }

    case anthropicMessages
    case openAIResponses
    /// `tokenLimitKey` is nil where the provider asks not to set one with JSON output.
    case chatCompletions(format: ResponseFormat, tokenLimitKey: String?)
}

struct AIEndpoint: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
}

/// The services a file's text can be sent to. The list and its addresses are
/// fixed in code, so a setting or a document can't point the app anywhere else.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, openAI, gemini, deepSeek, glm, qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .glm: "GLM"
        case .qwen: "Qwen"
        }
    }

    var company: String {
        switch self {
        case .claude: "Anthropic"
        case .openAI: "OpenAI"
        case .gemini: "Google"
        case .deepSeek: "DeepSeek"
        case .glm: "Z.ai (Zhipu)"
        case .qwen: "Alibaba Cloud"
        }
    }

    var api: AIProviderAPI {
        switch self {
        case .claude: .anthropicMessages
        case .openAI: .openAIResponses
        case .gemini: .chatCompletions(format: .jsonSchema, tokenLimitKey: "max_tokens")
        case .deepSeek, .glm: .chatCompletions(format: .jsonObject, tokenLimitKey: "max_tokens")
        case .qwen: .chatCompletions(format: .jsonObject, tokenLimitKey: nil)
        }
    }

    /// A key only works in the region it was issued for, so regions are a choice.
    var endpoints: [AIEndpoint] {
        func endpoint(_ id: String, _ name: String, _ url: String) -> AIEndpoint {
            AIEndpoint(id: id, name: name, url: URL(string: url)!)
        }
        switch self {
        case .claude:
            return [endpoint("default", "Default", "https://api.anthropic.com/v1/messages")]
        case .openAI:
            return [endpoint("default", "Default", "https://api.openai.com/v1/responses")]
        case .gemini:
            return [endpoint("default", "Default", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")]
        case .deepSeek:
            return [endpoint("default", "Default", "https://api.deepseek.com/chat/completions")]
        case .glm:
            return [
                endpoint("international", "International (z.ai)", "https://api.z.ai/api/paas/v4/chat/completions"),
                endpoint("china", "China (bigmodel.cn)", "https://open.bigmodel.cn/api/paas/v4/chat/completions"),
            ]
        case .qwen:
            return [
                endpoint("singapore", "Singapore", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"),
                endpoint("virginia", "Virginia", "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions"),
                endpoint("beijing", "Beijing", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"),
            ]
        }
    }

    /// Current models when this was written. Providers rename models often,
    /// so the model is an editable field and these are only suggestions.
    var suggestedModels: [String] {
        switch self {
        case .claude: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openAI: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-luna"]
        case .gemini: ["gemini-3.8-flash", "gemini-4-argon", "gemini-3.5-flash-lite"]
        case .deepSeek: ["deepseek-flash", "deepseek-v4-pro"]
        case .glm: ["glm-5.3", "glm-5.3-flash", "glm-5.2"]
        case .qwen: ["qwen3.8-max", "qwen3.7-plus"]
        }
    }

    func endpoint(id: String) -> AIEndpoint {
        endpoints.first { $0.id == id } ?? endpoints[0]
    }
}

/// A provider's non-secret choices. The key lives in the Keychain.
struct AIProviderSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var model: String
    var endpointID: String

    static func defaults(for provider: AIProvider) -> AIProviderSettings {
        AIProviderSettings(enabled: true, model: provider.suggestedModels[0], endpointID: provider.endpoints[0].id)
    }
}
