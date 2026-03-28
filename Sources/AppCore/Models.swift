import Foundation

public enum InputContextKind: String, Codable, Sendable {
    case plainText
    case selectedText
    case clipboardText
    case clipboardImage
    case recentScreenshot
    case remoteSession
}

public struct InputContext: Codable, Sendable {
    public let kind: InputContextKind
    public let sourceApp: String?
    public let payloadSummary: String
    public let textContent: String?
    public let imageDataURL: String?

    public init(
        kind: InputContextKind,
        sourceApp: String?,
        payloadSummary: String,
        textContent: String? = nil,
        imageDataURL: String? = nil
    ) {
        self.kind = kind
        self.sourceApp = sourceApp
        self.payloadSummary = payloadSummary
        self.textContent = textContent
        self.imageDataURL = imageDataURL
    }
}

public struct Transcript: Codable, Sendable {
    public let rawText: String
    public let normalizedText: String
    public let createdAt: Date

    public init(rawText: String, normalizedText: String, createdAt: Date = .now) {
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.createdAt = createdAt
    }
}

public struct AskRequest: Codable, Sendable {
    public let prompt: String
    public let context: InputContext?

    public init(prompt: String, context: InputContext?) {
        self.prompt = prompt
        self.context = context
    }
}

public struct AskResponse: Codable, Sendable {
    public let answer: String
    public let providerName: String

    public init(answer: String, providerName: String) {
        self.answer = answer
        self.providerName = providerName
    }
}

public enum InsertionMode: String, Codable, Sendable {
    case directAccessibility
    case clipboardPaste
    case delayedClipboardPaste
    case remoteSafePaste
}

public struct InsertionPlan: Codable, Sendable {
    public let mode: InsertionMode
    public let delayMilliseconds: Int
    public let attemptCount: Int
    public let retryIntervalMilliseconds: Int
    public let shouldRestoreClipboard: Bool

    public init(
        mode: InsertionMode,
        delayMilliseconds: Int,
        attemptCount: Int,
        retryIntervalMilliseconds: Int,
        shouldRestoreClipboard: Bool
    ) {
        self.mode = mode
        self.delayMilliseconds = delayMilliseconds
        self.attemptCount = attemptCount
        self.retryIntervalMilliseconds = retryIntervalMilliseconds
        self.shouldRestoreClipboard = shouldRestoreClipboard
    }
}
