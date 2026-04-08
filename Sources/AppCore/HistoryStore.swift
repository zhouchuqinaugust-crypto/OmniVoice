import Foundation

public enum HistoryEventKind: String, Codable, Sendable {
    case ask
    case transcript
}

public struct HistoryEvent: Codable, Sendable {
    public let id: UUID
    public let kind: HistoryEventKind
    public let createdAt: Date
    public let sourceApp: String?
    public let prompt: String?
    public let transcript: String?
    public let answer: String?
    public let contextSummary: String?

    public init(
        id: UUID = UUID(),
        kind: HistoryEventKind,
        createdAt: Date = .now,
        sourceApp: String?,
        prompt: String? = nil,
        transcript: String? = nil,
        answer: String? = nil,
        contextSummary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.prompt = prompt
        self.transcript = transcript
        self.answer = answer
        self.contextSummary = contextSummary
    }
}

public struct HistoryStore {
    private static let maximumEventCount = 1_000
    private static let fileCoordinator = HistoryFileCoordinator()

    private let fileManager: FileManager
    private let historyFilePath: String

    public init(
        historyFilePath: String = RuntimePaths.defaultHistoryPath(),
        fileManager: FileManager = .default
    ) {
        self.historyFilePath = historyFilePath
        self.fileManager = fileManager
    }

    public func recordAsk(prompt: String, result: AskPipelineResult) throws {
        let event = HistoryEvent(
            kind: .ask,
            sourceApp: result.context?.sourceApp,
            prompt: prompt,
            answer: result.response.answer,
            contextSummary: result.context?.payloadSummary
        )
        try append(event)
    }

    public func recordTranscript(_ transcript: Transcript, context: InputContext?) throws {
        let event = HistoryEvent(
            kind: .transcript,
            sourceApp: context?.sourceApp,
            transcript: transcript.normalizedText,
            contextSummary: context?.payloadSummary
        )
        try append(event)
    }

    public func recentEvents(limit: Int = 20) throws -> [HistoryEvent] {
        try Self.fileCoordinator.withLock {
            try recentEventsUnlocked(limit: limit)
        }
    }

    public func lastTranscript() throws -> HistoryEvent? {
        try recentEvents(limit: 100).last(where: { $0.kind == .transcript })
    }

    public func lastAnswer() throws -> HistoryEvent? {
        try recentEvents(limit: 100).last(where: { $0.kind == .ask })
    }

    private func recentEventsUnlocked(limit: Int) throws -> [HistoryEvent] {
        guard fileManager.fileExists(atPath: historyFilePath) else {
            return []
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: historyFilePath))
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try content
            .split(separator: "\n")
            .suffix(max(0, limit))
            .map { line in
                try decoder.decode(HistoryEvent.self, from: Data(line.utf8))
            }
    }

    private func append(_ event: HistoryEvent) throws {
        try Self.fileCoordinator.withLock {
            let url = URL(fileURLWithPath: historyFilePath)
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(event)

            if fileManager.fileExists(atPath: historyFilePath) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
            } else {
                try Data(data + Data("\n".utf8)).write(to: url)
            }

            try rotateIfNeeded(url: url)
        }
    }

    private func rotateIfNeeded(url: URL) throws {
        let events = try recentEventsUnlocked(limit: Self.maximumEventCount + 1)
        guard events.count > Self.maximumEventCount else {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let retainedEvents = events.suffix(Self.maximumEventCount)
        let data = try retainedEvents.reduce(into: Data()) { partialResult, event in
            try partialResult.append(encoder.encode(event))
            partialResult.append(Data("\n".utf8))
        }
        try data.write(to: url, options: [.atomic])
    }
}

private final class HistoryFileCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
