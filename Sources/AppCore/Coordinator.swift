import Foundation

public struct PipelineResult: Sendable {
    public let transcript: Transcript
    public let insertionPlan: InsertionPlan
    public let askResponse: AskResponse

    public init(transcript: Transcript, insertionPlan: InsertionPlan, askResponse: AskResponse) {
        self.transcript = transcript
        self.insertionPlan = insertionPlan
        self.askResponse = askResponse
    }
}

public struct AskPipelineResult: Codable, Sendable {
    public let context: InputContext?
    public let response: AskResponse

    public init(context: InputContext?, response: AskResponse) {
        self.context = context
        self.response = response
    }
}

public struct TranscriptionPipelineResult: Codable, Sendable {
    public let context: InputContext?
    public let transcript: Transcript
    public let insertionPlan: InsertionPlan?

    public init(context: InputContext?, transcript: Transcript, insertionPlan: InsertionPlan?) {
        self.context = context
        self.transcript = transcript
        self.insertionPlan = insertionPlan
    }
}

public struct AppCoordinator: Sendable {
    private let sttProvider: any STTProviding
    private let askProvider: any AskProviding
    private let dictionaryEngine: DictionaryEngine
    private let insertionEngine: InsertionEngine

    public init(
        sttProvider: any STTProviding,
        askProvider: any AskProviding,
        dictionaryEngine: DictionaryEngine,
        insertionEngine: InsertionEngine
    ) {
        self.sttProvider = sttProvider
        self.askProvider = askProvider
        self.dictionaryEngine = dictionaryEngine
        self.insertionEngine = insertionEngine
    }

    public func runDemo(context: InputContext) async throws -> PipelineResult {
        let rawTranscript = try await sttProvider.transcribeDemoUtterance()
        let normalizedTranscript = dictionaryEngine.normalize(rawTranscript)
        let transcript = Transcript(rawText: rawTranscript, normalizedText: normalizedTranscript)
        let insertionPlan = insertionEngine.plan(for: context)
        let askResponse = try await askProvider.ask(
            AskRequest(
                prompt: "Summarize what to do with this transcript.",
                context: context
            )
        )

        return PipelineResult(
            transcript: transcript,
            insertionPlan: insertionPlan,
            askResponse: askResponse
        )
    }

    public func ask(prompt: String, context: InputContext?) async throws -> AskPipelineResult {
        let response = try await askProvider.ask(
            AskRequest(prompt: prompt, context: context)
        )

        return AskPipelineResult(context: context, response: response)
    }

    public func transcribeAudioFile(
        at fileURL: URL,
        context: InputContext?,
        shouldInsert: Bool
    ) async throws -> TranscriptionPipelineResult {
        let rawTranscript = try await sttProvider.transcribeAudioFile(at: fileURL)
        try Task.checkCancellation()
        let normalizedTranscript = dictionaryEngine.normalize(rawTranscript)
        let transcript = Transcript(rawText: rawTranscript, normalizedText: normalizedTranscript)

        let insertionPlan: InsertionPlan?
        if shouldInsert {
            try Task.checkCancellation()
            insertionPlan = try await insertionEngine.insert(text: normalizedTranscript, context: context)
        } else {
            insertionPlan = nil
        }

        return TranscriptionPipelineResult(
            context: context,
            transcript: transcript,
            insertionPlan: insertionPlan
        )
    }

    public func insert(text: String, context: InputContext?) async throws -> InsertionPlan {
        try await insertionEngine.insert(text: text, context: context)
    }
}
