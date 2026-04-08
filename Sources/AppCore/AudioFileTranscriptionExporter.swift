import Foundation

public struct AudioFileTranscriptionExportOptions: Sendable {
    public let outputFileURL: URL?
    public let shouldDiarize: Bool
    public let chunkDurationSeconds: Int
    public let progressHandler: (@Sendable (String) -> Void)?

    public init(
        outputFileURL: URL? = nil,
        shouldDiarize: Bool = false,
        chunkDurationSeconds: Int = 900,
        progressHandler: (@Sendable (String) -> Void)? = nil
    ) {
        self.outputFileURL = outputFileURL
        self.shouldDiarize = shouldDiarize
        self.chunkDurationSeconds = max(60, chunkDurationSeconds)
        self.progressHandler = progressHandler
    }
}

public struct AudioFileTranscriptSegment: Codable, Sendable {
    public let startTimeSeconds: Double?
    public let endTimeSeconds: Double?
    public let speakerLabel: String?
    public let rawText: String
    public let normalizedText: String

    public init(
        startTimeSeconds: Double?,
        endTimeSeconds: Double?,
        speakerLabel: String?,
        rawText: String,
        normalizedText: String
    ) {
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.speakerLabel = speakerLabel
        self.rawText = rawText
        self.normalizedText = normalizedText
    }
}

public struct AudioFileTranscriptionExportResult: Codable, Sendable {
    public let inputFilePath: String
    public let outputFilePath: String
    public let providerName: String
    public let durationSeconds: Double?
    public let diarizationRequested: Bool
    public let diarizationPerformed: Bool
    public let diarizationMethod: String?
    public let warnings: [String]
    public let speakerCount: Int
    public let transcript: Transcript
    public let segments: [AudioFileTranscriptSegment]

    public init(
        inputFilePath: String,
        outputFilePath: String,
        providerName: String,
        durationSeconds: Double?,
        diarizationRequested: Bool,
        diarizationPerformed: Bool,
        diarizationMethod: String?,
        warnings: [String],
        speakerCount: Int,
        transcript: Transcript,
        segments: [AudioFileTranscriptSegment]
    ) {
        self.inputFilePath = inputFilePath
        self.outputFilePath = outputFilePath
        self.providerName = providerName
        self.durationSeconds = durationSeconds
        self.diarizationRequested = diarizationRequested
        self.diarizationPerformed = diarizationPerformed
        self.diarizationMethod = diarizationMethod
        self.warnings = warnings
        self.speakerCount = speakerCount
        self.transcript = transcript
        self.segments = segments
    }
}

public struct AudioFileTranscriptionExporter: Sendable {
    private let sttConfiguration: STTConfiguration
    private let sttProvider: any STTProviding
    private let dictionaryEngine: DictionaryEngine
    private let processRunner: ProcessRunning

    public init(
        sttConfiguration: STTConfiguration,
        sttProvider: any STTProviding,
        dictionaryEngine: DictionaryEngine,
        processRunner: ProcessRunning = DefaultProcessRunner()
    ) {
        self.sttConfiguration = sttConfiguration
        self.sttProvider = sttProvider
        self.dictionaryEngine = dictionaryEngine
        self.processRunner = processRunner
    }

    public func exportTranscription(
        of inputFileURL: URL,
        options: AudioFileTranscriptionExportOptions = AudioFileTranscriptionExportOptions()
    ) async throws -> AudioFileTranscriptionExportResult {
        guard FileManager.default.fileExists(atPath: inputFileURL.path) else {
            throw STTProviderError.audioFileNotFound(inputFileURL.path)
        }

        let outputFileURL = resolvedOutputFileURL(
            for: inputFileURL,
            explicitOutputFileURL: options.outputFileURL
        )

        let result: AudioFileTranscriptionExportResult
        if shouldUseMLXFileExporter {
            result = try await exportWithMLX(
                inputFileURL: inputFileURL,
                outputFileURL: outputFileURL,
                options: options
            )
        } else {
            result = try await exportWithProviderFallback(
                inputFileURL: inputFileURL,
                outputFileURL: outputFileURL,
                options: options
            )
        }

        try writeTranscriptFile(result, to: outputFileURL)
        return result
    }

    private var shouldUseMLXFileExporter: Bool {
        guard sttConfiguration.acceleration == .mlx,
              let pythonPath = sttConfiguration.mlxPythonPath,
              let mlxModel = sttConfiguration.mlxModel else {
            return false
        }

        return FileManager.default.isExecutableFile(atPath: pythonPath) && !mlxModel.isEmpty
    }

    private func exportWithProviderFallback(
        inputFileURL: URL,
        outputFileURL: URL,
        options: AudioFileTranscriptionExportOptions
    ) async throws -> AudioFileTranscriptionExportResult {
        let rawTranscript = try await sttProvider.transcribeAudioFile(at: inputFileURL)
        let finalizedRawTranscript = try TranscriptSanitizer.finalizedTranscript(
            from: rawTranscript,
            promptInstruction: sttConfiguration.promptInstruction
        )
        let normalizedTranscript = dictionaryEngine.normalize(finalizedRawTranscript)
        let transcript = Transcript(
            rawText: finalizedRawTranscript,
            normalizedText: normalizedTranscript
        )

        var warnings: [String] = []
        if options.shouldDiarize {
            warnings.append(
                "Speaker diarization is only available through the MLX file transcription path. The current STT provider exported plain transcript text without speaker labels."
            )
        }

        return AudioFileTranscriptionExportResult(
            inputFilePath: inputFileURL.path,
            outputFilePath: outputFileURL.path,
            providerName: sttProvider.providerName,
            durationSeconds: nil,
            diarizationRequested: options.shouldDiarize,
            diarizationPerformed: false,
            diarizationMethod: nil,
            warnings: warnings,
            speakerCount: 0,
            transcript: transcript,
            segments: []
        )
    }

    private func exportWithMLX(
        inputFileURL: URL,
        outputFileURL: URL,
        options: AudioFileTranscriptionExportOptions
    ) async throws -> AudioFileTranscriptionExportResult {
        guard let pythonPath = sttConfiguration.mlxPythonPath, !pythonPath.isEmpty else {
            throw STTProviderError.missingMLXPythonPath
        }

        guard let mlxModel = sttConfiguration.mlxModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mlxModel.isEmpty else {
            throw STTProviderError.missingMLXModel
        }

        let runnerScript = RuntimePaths.resolveReadableAppRelativePath("scripts/mlx_transcribe_file.py")
        guard FileManager.default.fileExists(atPath: runnerScript) else {
            throw STTProviderError.missingMLXRunnerScript
        }

        var arguments = [
            runnerScript,
            "--audio", inputFileURL.path,
            "--model", mlxModel,
            "--chunk-seconds", "\(options.chunkDurationSeconds)",
        ]

        let candidateLanguages = candidateLanguages(from: sttConfiguration.localeHints)
        if candidateLanguages.count > 1 {
            arguments.append(contentsOf: ["--candidate-languages", candidateLanguages.joined(separator: ",")])
        } else if let language = candidateLanguages.first {
            arguments.append(contentsOf: ["--language", language])
        }

        if let promptArgument = promptArgument() {
            arguments.append(contentsOf: ["--prompt", promptArgument])
        }

        if options.shouldDiarize {
            arguments.append("--diarize")
        }

        let processResult: ProcessResult
        if let progressHandler = options.progressHandler {
            processResult = try await runCancellableProcess(
                executable: pythonPath,
                arguments: arguments,
                onStandardErrorLine: progressHandler
            )
        } else if let cancellableRunner = processRunner as? any CancellableProcessRunning {
            processResult = try await cancellableRunner.runCancellable(
                executable: pythonPath,
                arguments: arguments
            )
        } else {
            processResult = try processRunner.run(executable: pythonPath, arguments: arguments)
        }

        guard processResult.exitCode == 0 else {
            throw STTProviderError.commandFailed(processResult.exitCode, processResult.combinedOutput)
        }

        let output = processResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8) else {
            throw STTProviderError.invalidMLXResponse(output)
        }

        let decoder = JSONDecoder()
        let envelope: MLXFileTranscriptionEnvelope
        do {
            envelope = try decoder.decode(MLXFileTranscriptionEnvelope.self, from: data)
        } catch {
            throw STTProviderError.invalidMLXResponse(output)
        }

        let segments = normalizedSegments(from: envelope.segments)
        let rawTranscript = combinedRawTranscript(from: envelope, segments: segments)
        let finalizedRawTranscript = try TranscriptSanitizer.finalizedTranscript(
            from: rawTranscript,
            promptInstruction: sttConfiguration.promptInstruction
        )
        let transcript = Transcript(
            rawText: finalizedRawTranscript,
            normalizedText: dictionaryEngine.normalize(finalizedRawTranscript)
        )

        let speakerCount = Set(segments.compactMap(\.speakerLabel)).count

        return AudioFileTranscriptionExportResult(
            inputFilePath: inputFileURL.path,
            outputFilePath: outputFileURL.path,
            providerName: sttProvider.providerName,
            durationSeconds: envelope.durationSeconds,
            diarizationRequested: options.shouldDiarize,
            diarizationPerformed: envelope.diarizationPerformed,
            diarizationMethod: envelope.diarizationMethod,
            warnings: envelope.warnings,
            speakerCount: speakerCount,
            transcript: transcript,
            segments: segments
        )
    }

    private func normalizedSegments(from segments: [MLXFileTranscriptionSegment]) -> [AudioFileTranscriptSegment] {
        segments.compactMap { segment in
            let rawText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else {
                return nil
            }

            return AudioFileTranscriptSegment(
                startTimeSeconds: segment.start,
                endTimeSeconds: segment.end,
                speakerLabel: segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                rawText: rawText,
                normalizedText: dictionaryEngine.normalize(rawText)
            )
        }
    }

    private func combinedRawTranscript(
        from envelope: MLXFileTranscriptionEnvelope,
        segments: [AudioFileTranscriptSegment]
    ) -> String {
        let rawText = envelope.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawText.isEmpty {
            return rawText
        }

        return segments
            .map(\.rawText)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptArgument() -> String? {
        let lines = promptLines()
        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private func promptLines() -> [String] {
        var lines: [String] = []
        if let promptInstruction = normalizedPromptInstruction() {
            lines.append(promptInstruction)
        }
        lines.append(contentsOf: sttConfiguration.promptTerms)
        return lines
    }

    private func normalizedPromptInstruction() -> String? {
        guard let promptInstruction = sttConfiguration.promptInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !promptInstruction.isEmpty else {
            return nil
        }
        return promptInstruction
    }

    private func candidateLanguages(from localeHints: [String]) -> [String] {
        var families: [String] = []
        for locale in localeHints {
            let normalized = locale.lowercased()
            let family: String
            if normalized.hasPrefix("zh") {
                family = "zh"
            } else if normalized.hasPrefix("en") {
                family = "en"
            } else {
                continue
            }

            if !families.contains(family) {
                families.append(family)
            }
        }
        return families
    }

    private func resolvedOutputFileURL(
        for inputFileURL: URL,
        explicitOutputFileURL: URL?
    ) -> URL {
        guard let explicitOutputFileURL else {
            let fileName = inputFileURL.deletingPathExtension().lastPathComponent + ".transcript.txt"
            return inputFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
        }

        return explicitOutputFileURL
    }

    private func writeTranscriptFile(
        _ result: AudioFileTranscriptionExportResult,
        to outputFileURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: outputFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let contents = renderedTranscript(result)
        try contents.write(to: outputFileURL, atomically: true, encoding: .utf8)
    }

    private func renderedTranscript(_ result: AudioFileTranscriptionExportResult) -> String {
        var lines: [String] = [
            "Source: \(result.inputFilePath)",
            "Provider: \(result.providerName)",
            "Generated At: \(ISO8601DateFormatter().string(from: Date()))",
        ]

        if let durationSeconds = result.durationSeconds {
            lines.append("Duration: \(formattedTimestamp(durationSeconds))")
        }

        if result.diarizationRequested {
            if result.diarizationPerformed {
                let detail = result.diarizationMethod ?? "enabled"
                lines.append("Speaker Diarization: \(detail)")
            } else {
                lines.append("Speaker Diarization: unavailable")
            }
        }

        if !result.warnings.isEmpty {
            lines.append("Warnings: \(result.warnings.joined(separator: " | "))")
        }

        lines.append("")

        if result.segments.isEmpty {
            lines.append(result.transcript.normalizedText)
        } else {
            lines.append(contentsOf: result.segments.map(renderedSegmentLine))
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func renderedSegmentLine(_ segment: AudioFileTranscriptSegment) -> String {
        let text = segment.normalizedText
        let timestamp = formattedTimestampRange(
            startTimeSeconds: segment.startTimeSeconds,
            endTimeSeconds: segment.endTimeSeconds
        )

        switch (segment.speakerLabel, timestamp) {
        case let (.some(speaker), .some(timestamp)):
            return "[\(speaker) \(timestamp)] \(text)"
        case let (.some(speaker), .none):
            return "[\(speaker)] \(text)"
        case let (.none, .some(timestamp)):
            return "[\(timestamp)] \(text)"
        case (.none, .none):
            return text
        }
    }

    private func formattedTimestampRange(
        startTimeSeconds: Double?,
        endTimeSeconds: Double?
    ) -> String? {
        guard let startTimeSeconds else {
            return nil
        }

        let start = formattedTimestamp(startTimeSeconds)
        if let endTimeSeconds {
            return "\(start) - \(formattedTimestamp(endTimeSeconds))"
        }

        return start
    }

    private func formattedTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private func runCancellableProcess(
        executable: String,
        arguments: [String],
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = StreamingOutputBuffer()
        let stderrBuffer = StreamingOutputBuffer()
        let state = FileExportProcessContinuationState()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutBuffer.append(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrBuffer.append(handle.availableData, lineHandler: onStandardErrorLine)
                }

                process.terminationHandler = { terminatedProcess in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    stderrBuffer.append(
                        stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        lineHandler: onStandardErrorLine
                    )
                    stderrBuffer.flushPendingLine(lineHandler: onStandardErrorLine)

                    state.resume(
                        returning: ProcessResult(
                            exitCode: terminatedProcess.terminationStatus,
                            standardOutput: stdoutBuffer.stringValue(),
                            standardError: stderrBuffer.stringValue()
                        )
                    )
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    state.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        }
    }
}

private final class StreamingOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pendingLine = ""

    func append(
        _ chunk: Data,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) {
        guard !chunk.isEmpty else {
            return
        }

        let lines: [String]
        lock.lock()
        data.append(chunk)
        if lineHandler != nil {
            pendingLine += String(decoding: chunk, as: UTF8.self)
            var completedLines: [String] = []
            while let newlineIndex = pendingLine.firstIndex(of: "\n") {
                let line = String(pendingLine[..<newlineIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    completedLines.append(line)
                }
                pendingLine.removeSubrange(...newlineIndex)
            }
            lines = completedLines
        } else {
            lines = []
        }
        lock.unlock()

        for line in lines {
            lineHandler?(line)
        }
    }

    func flushPendingLine(lineHandler: @Sendable (String) -> Void) {
        let line: String?
        lock.lock()
        let pending = pendingLine.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLine = ""
        line = pending.isEmpty ? nil : pending
        lock.unlock()

        if let line {
            lineHandler(line)
        }
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class FileExportProcessContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    func setContinuation(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(returning result: ProcessResult) {
        resume { continuation in
            continuation.resume(returning: result)
        }
    }

    func resume(throwing error: Error) {
        resume { continuation in
            continuation.resume(throwing: error)
        }
    }

    private func resume(_ action: (CheckedContinuation<ProcessResult, Error>) -> Void) {
        lock.lock()
        guard !hasResumed, let continuation else {
            lock.unlock()
            return
        }
        hasResumed = true
        self.continuation = nil
        lock.unlock()

        action(continuation)
    }
}

private struct MLXFileTranscriptionEnvelope: Codable {
    let text: String
    let language: String?
    let durationSeconds: Double?
    let diarizationPerformed: Bool
    let diarizationMethod: String?
    let warnings: [String]
    let segments: [MLXFileTranscriptionSegment]

    private enum CodingKeys: String, CodingKey {
        case text
        case language
        case durationSeconds = "duration_seconds"
        case diarizationPerformed = "diarization_performed"
        case diarizationMethod = "diarization_method"
        case warnings
        case segments
    }
}

private struct MLXFileTranscriptionSegment: Codable {
    let start: Double?
    let end: Double?
    let text: String
    let speaker: String?
}
