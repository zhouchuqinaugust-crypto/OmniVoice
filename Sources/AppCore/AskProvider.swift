import Foundation

public protocol AskProviding: Sendable {
    var providerName: String { get }
    func ask(_ request: AskRequest) async throws -> AskResponse
}

public enum AskProviderError: LocalizedError, Sendable {
    case invalidBaseURL(String)
    case missingAPIKey(environmentVariable: String)
    case unexpectedStatusCode(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Invalid Ask provider base URL: \(value)"
        case .missingAPIKey(let environmentVariable):
            return "Missing API key in environment variable: \(environmentVariable)"
        case .unexpectedStatusCode(let statusCode, let body):
            return "Ask provider returned HTTP \(statusCode): \(body)"
        case .invalidResponse:
            return "Ask provider returned an invalid response payload."
        }
    }
}

public struct MockAskProvider: AskProviding {
    public let providerName: String

    public init(providerName: String = "mock-openai-compatible") {
        self.providerName = providerName
    }

    public func ask(_ request: AskRequest) async throws -> AskResponse {
        let contextDescription = request.context?.payloadSummary ?? "no-context"
        return AskResponse(
            answer: "Mock answer for: \(request.prompt) [context: \(contextDescription)]",
            providerName: providerName
        )
    }
}

public struct OpenAICompatibleAskProvider: AskProviding {
    public let providerName: String

    private let configuration: AskConfiguration
    private let apiKey: String
    private let urlSession: URLSession
    private let applicationName: String

    public init(
        providerName: String,
        configuration: AskConfiguration,
        apiKey: String,
        applicationName: String,
        urlSession: URLSession = .shared
    ) {
        self.providerName = providerName
        self.configuration = configuration
        self.apiKey = apiKey
        self.applicationName = applicationName
        self.urlSession = urlSession
    }

    public func ask(_ request: AskRequest) async throws -> AskResponse {
        guard let endpoint = URL(string: configuration.baseURL + "/chat/completions") else {
            throw AskProviderError.invalidBaseURL(configuration.baseURL)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if configuration.provider == .openRouter || configuration.baseURL.contains("openrouter.ai") {
            urlRequest.setValue(applicationName, forHTTPHeaderField: "X-Title")
        }

        let body = ChatCompletionsRequest(
            model: configuration.defaultModel,
            messages: buildMessages(for: request),
            temperature: 0.2
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AskProviderError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw AskProviderError.unexpectedStatusCode(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let answer = decoded.choices.first?.message.flattenedText, !answer.isEmpty else {
            throw AskProviderError.invalidResponse
        }

        return AskResponse(answer: answer, providerName: providerName)
    }

    private func buildMessages(for request: AskRequest) -> [ChatMessage] {
        let system = ChatMessage(
            role: "system",
            content: [.text(configuration.systemPrompt)]
        )

        var parts: [MessagePart] = [
            .text("User question: \(request.prompt)")
        ]

        if let context = request.context {
            parts.append(.text("Context kind: \(context.kind.rawValue)"))

            if let sourceApp = context.sourceApp {
                parts.append(.text("Source app: \(sourceApp)"))
            }

            parts.append(.text("Context summary: \(context.payloadSummary)"))

            if let textContent = context.textContent, !textContent.isEmpty {
                parts.append(.text("Context text:\n\(textContent)"))
            }

            if configuration.supportsImageContext,
               let imageDataURL = context.imageDataURL,
               !imageDataURL.isEmpty {
                parts.append(.imageURL(imageDataURL))
            }
        }

        let user = ChatMessage(role: "user", content: parts)
        return [system, user]
    }
}

public enum AskProviderFactory {
    public static func makeProvider(
        configuration: AskConfiguration,
        applicationName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainStore: KeychainStoring = SystemKeychainStore()
    ) throws -> any AskProviding {
        let apiKey: String?
        if let environmentValue = environment[configuration.apiKeyEnvironmentVariable], !environmentValue.isEmpty {
            apiKey = environmentValue
        } else if let service = configuration.keychainService,
                  let account = configuration.keychainAccount {
            if let currentValue = try? keychainStore.readPassword(service: service, account: account),
               !currentValue.isEmpty {
                apiKey = currentValue
            } else {
                apiKey = KeychainServiceCompatibility
                    .legacyServices(for: service)
                    .lazy
                    .compactMap { legacyService in
                        try? keychainStore.readPassword(service: legacyService, account: account)
                    }
                    .first(where: { !$0.isEmpty })
            }
        } else {
            apiKey = nil
        }

        guard let apiKey, !apiKey.isEmpty else {
            throw AskProviderError.missingAPIKey(environmentVariable: configuration.apiKeyEnvironmentVariable)
        }

        let providerName: String
        switch configuration.provider {
        case .openAI:
            providerName = "openai-compatible"
        case .openRouter:
            providerName = "openrouter"
        case .customOpenAICompatible:
            providerName = "custom-openai-compatible"
        }

        return OpenAICompatibleAskProvider(
            providerName: providerName,
            configuration: configuration,
            apiKey: apiKey,
            applicationName: applicationName
        )
    }
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Encodable, Decodable {
    let role: String
    let content: [MessagePart]
}

private enum MessagePart: Encodable, Decodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageURL(let value):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: value), forKey: .imageURL)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            let image = try container.decode(ImageURL.self, forKey: .imageURL)
            self = .imageURL(image.url)
        default:
            self = .text("")
        }
    }
}

private struct ImageURL: Codable {
    let url: String
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: ResponseContent

        var flattenedText: String {
            switch content {
            case .text(let value):
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .parts(let values):
                return values
                    .compactMap { part in
                        if case .outputText(let text) = part {
                            return text
                        }

                        return nil
                    }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

private enum ResponseContent: Decodable {
    case text(String)
    case parts([ResponsePart])

    init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()

        if let text = try? singleValueContainer.decode(String.self) {
            self = .text(text)
            return
        }

        self = .parts(try singleValueContainer.decode([ResponsePart].self))
    }
}

private enum ResponsePart: Decodable {
    case outputText(String)
    case other

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""

        if type == "text", let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .outputText(text)
        } else {
            self = .other
        }
    }
}
