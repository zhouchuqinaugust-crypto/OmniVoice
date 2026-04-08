import Darwin
import Foundation
import Speech

public protocol STTProviding: Sendable {
    var providerName: String { get }
    func transcribeDemoUtterance() async throws -> String
    func transcribeAudioFile(at fileURL: URL) async throws -> String
}

public enum STTProviderError: LocalizedError, Sendable {
    case missingBinaryPath
    case missingModelPath
    case missingMLXPythonPath
    case missingMLXModel
    case missingMLXRunnerScript
    case audioFileNotFound(String)
    case commandFailed(Int32, String)
    case emptyTranscript
    case speechRecognitionUnauthorized(String)
    case speechRecognizerUnavailable(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(Int)
    case unsupportedMode(String)
    case unsupportedAcceleration(String)
    case invalidMLXResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingBinaryPath:
            return "Local STT binary path is not configured."
        case .missingModelPath:
            return "Local STT model path is not configured."
        case .missingMLXPythonPath:
            return "MLX Python runtime path is not configured."
        case .missingMLXModel:
            return "MLX model repo or local path is not configured."
        case .missingMLXRunnerScript:
            return "MLX transcription runner script could not be found."
        case .audioFileNotFound(let path):
            return "Audio file does not exist: \(path)"
        case .commandFailed(let code, let output):
            return "Local STT process failed with exit code \(code): \(output)"
        case .emptyTranscript:
            return "No speech was detected in the recording."
        case .speechRecognitionUnauthorized(let status):
            return "Speech recognition permission is not available: \(status)"
        case .speechRecognizerUnavailable(let reason):
            return "Speech recognizer is unavailable: \(reason)"
        case .transcriptionFailed(let reason):
            return "Speech transcription failed: \(reason)"
        case .transcriptionTimedOut(let seconds):
            return "Speech transcription timed out after \(seconds) seconds."
        case .unsupportedMode(let mode):
            return "The configured STT mode is not supported yet: \(mode)"
        case .unsupportedAcceleration(let acceleration):
            return "The configured STT acceleration is not supported yet: \(acceleration)"
        case .invalidMLXResponse(let output):
            return "MLX STT returned an invalid response: \(output)"
        }
    }
}

enum TranscriptSanitizer {
    private static let builtInPromptArtifacts: Set<String> = Set(
        [
            ChineseScriptPreference.preserve.whisperPromptInstruction,
            ChineseScriptPreference.simplified.whisperPromptInstruction,
            ChineseScriptPreference.traditional.whisperPromptInstruction,
        ]
        .compactMap { $0 }
        .map(canonicalize)
    )

    static func finalizedTranscript(
        from rawTranscript: String,
        promptInstruction: String? = nil
    ) throws -> String {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw STTProviderError.emptyTranscript
        }

        let leakedPromptArtifacts = leakedPromptArtifacts(promptInstruction: promptInstruction)
        let canonicalTranscript = canonicalize(transcript)
        guard !isPromptLeak(canonicalTranscript, artifacts: leakedPromptArtifacts) else {
            throw STTProviderError.emptyTranscript
        }

        return transcript
    }

    private static func leakedPromptArtifacts(promptInstruction: String?) -> Set<String> {
        var artifacts = builtInPromptArtifacts
        if let promptInstruction = promptInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !promptInstruction.isEmpty {
            artifacts.insert(canonicalize(promptInstruction))
        }
        return artifacts
    }

    private static func isPromptLeak(_ canonicalTranscript: String, artifacts: Set<String>) -> Bool {
        guard !canonicalTranscript.isEmpty else {
            return true
        }

        if artifacts.contains(canonicalTranscript) {
            return true
        }

        return artifacts.contains { artifact in
            guard !artifact.isEmpty else {
                return false
            }

            let shorterCount = min(canonicalTranscript.count, artifact.count)
            let longerCount = max(canonicalTranscript.count, artifact.count)
            guard shorterCount >= 12 else {
                return false
            }

            let overlapThreshold = Int(Double(longerCount) * 0.6)
            guard shorterCount >= overlapThreshold else {
                return false
            }

            return artifact.contains(canonicalTranscript) || canonicalTranscript.contains(artifact)
        }
    }

    private static func canonicalize(_ text: String) -> String {
        let filteredScalars = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.punctuationCharacters.contains(scalar) &&
                !CharacterSet.symbols.contains(scalar)
            }

        return String(String.UnicodeScalarView(filteredScalars))
    }
}

public struct LocalWhisperProvider: STTProviding {
    public let providerName = "local-whisper"

    private let configuration: STTConfiguration
    private let processRunner: ProcessRunning

    public init(
        configuration: STTConfiguration = STTConfiguration(mode: .localWhisper, localeHints: []),
        processRunner: ProcessRunning = DefaultProcessRunner()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
    }

    public func transcribeDemoUtterance() async throws -> String {
        "请把 OpenClaw 的部署文档发给 Horizon Client 团队。"
    }

    public func transcribeAudioFile(at fileURL: URL) async throws -> String {
        guard let binaryPath = configuration.binaryPath, !binaryPath.isEmpty else {
            throw STTProviderError.missingBinaryPath
        }

        guard let modelPath = configuration.modelPath, !modelPath.isEmpty else {
            throw STTProviderError.missingModelPath
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw STTProviderError.audioFileNotFound(fileURL.path)
        }

        switch configuration.acceleration {
        case .cpu:
            return try await transcribeWhisper(
                executionMode: .cpu,
                binaryPath: binaryPath,
                modelPath: modelPath,
                fileURL: fileURL
            )
        case .auto:
            return try await transcribeAutomatically(
                binaryPath: binaryPath,
                modelPath: modelPath,
                fileURL: fileURL
            )
        case .metal:
            do {
                return try await transcribeWhisper(
                    executionMode: .metal,
                    binaryPath: binaryPath,
                    modelPath: modelPath,
                    fileURL: fileURL
                )
            } catch {
                throw STTProviderError.transcriptionFailed(
                    "Metal acceleration failed. Switch STT acceleration to CPU or Auto. Underlying error: \(error.localizedDescription)"
                )
            }
        case .mlx:
            throw STTProviderError.unsupportedAcceleration(configuration.acceleration.rawValue)
        }
    }

    private func promptArgument() -> String? {
        let promptLines = promptLines()
        guard !promptLines.isEmpty else {
            return nil
        }
        return promptLines.joined(separator: "\n")
    }

    private func promptLines() -> [String] {
        var lines: [String] = []
        if let promptInstruction = normalizedPromptInstruction() {
            lines.append(promptInstruction)
        }
        lines.append(contentsOf: configuration.promptTerms)
        return lines
    }

    private func normalizedPromptInstruction() -> String? {
        guard let promptInstruction = configuration.promptInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !promptInstruction.isEmpty else {
            return nil
        }
        return promptInstruction
    }

    private func transcribeAutomatically(
        binaryPath: String,
        modelPath: String,
        fileURL: URL
    ) async throws -> String {
        let executionKey = "\(binaryPath)|\(modelPath)"
        if await WhisperAccelerationCache.shared.shouldAvoidMetal(for: executionKey) {
            return try await transcribeWhisper(
                executionMode: .cpu,
                binaryPath: binaryPath,
                modelPath: modelPath,
                fileURL: fileURL
            )
        }

        do {
            return try await transcribeWhisper(
                executionMode: .metal,
                binaryPath: binaryPath,
                modelPath: modelPath,
                fileURL: fileURL
            )
        } catch {
            guard shouldFallbackToCPU(after: error) else {
                throw error
            }

            await WhisperAccelerationCache.shared.markMetalFailed(for: executionKey)
            return try await transcribeWhisper(
                executionMode: .cpu,
                binaryPath: binaryPath,
                modelPath: modelPath,
                fileURL: fileURL
            )
        }
    }

    private func transcribeWhisper(
        executionMode: WhisperExecutionMode,
        binaryPath: String,
        modelPath: String,
        fileURL: URL
    ) async throws -> String {
        let arguments = whisperArguments(
            executionMode: executionMode,
            modelPath: modelPath,
            fileURL: fileURL
        )

        let result: ProcessResult
        if let cancellableRunner = processRunner as? any CancellableProcessRunning {
            result = try await runShortTranscriptionProcess(
                executable: binaryPath,
                arguments: arguments,
                cancellableRunner: cancellableRunner
            )
        } else {
            result = try processRunner.run(executable: binaryPath, arguments: arguments)
        }

        guard result.exitCode == 0 else {
            throw STTProviderError.commandFailed(result.exitCode, result.combinedOutput)
        }

        return try TranscriptSanitizer.finalizedTranscript(
            from: result.standardOutput,
            promptInstruction: normalizedPromptInstruction()
        )
    }

    private func whisperArguments(
        executionMode: WhisperExecutionMode,
        modelPath: String,
        fileURL: URL
    ) -> [String] {
        var arguments = [
            "-m", modelPath,
            "-f", fileURL.path,
        ]

        if executionMode == .cpu {
            arguments.append("-ng")
        }

        arguments.append(contentsOf: [
            "-nt",
            "-np",
            "-t", "\(recommendedThreadCount())",
        ])

        if !configuration.localeHints.isEmpty {
            arguments.append(contentsOf: ["-l", languageArgument(from: configuration.localeHints)])
        }

        if let promptArgument = promptArgument() {
            arguments.append(contentsOf: ["--prompt", promptArgument])
        }

        return arguments
    }

    private func recommendedThreadCount() -> Int {
        if let configuredThreadCount = configuration.threadCount, configuredThreadCount > 0 {
            return configuredThreadCount
        }

        if let performanceCoreCount = systemCPUCount(named: "hw.perflevel0.physicalcpu") {
            return performanceCoreCount
        }

        let activeProcessorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        if activeProcessorCount <= 8 {
            return activeProcessorCount
        }

        return min(activeProcessorCount, 10)
    }

    private func languageArgument(from localeHints: [String]) -> String {
        guard !localeHints.isEmpty else {
            return "auto"
        }

        let families = Set(localeHints.map { locale in
            let normalized = locale.lowercased()
            if normalized.hasPrefix("zh") {
                return "zh"
            }
            if normalized.hasPrefix("en") {
                return "en"
            }
            return "auto"
        })

        if families.count != 1 {
            return "auto"
        }

        guard let family = families.first else {
            return "auto"
        }

        if family == "zh" {
            return "zh"
        }

        if family == "en" {
            return "en"
        }

        return "auto"
    }

    private func systemCPUCount(named name: String) -> Int? {
        var result: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &result, &size, nil, 0) == 0, result > 0 else {
            return nil
        }
        return Int(result)
    }

    private func shouldFallbackToCPU(after error: Error) -> Bool {
        guard let error = error as? STTProviderError else {
            return false
        }

        switch error {
        case .commandFailed, .emptyTranscript, .transcriptionFailed:
            return true
        default:
            return false
        }
    }
}

private enum WhisperExecutionMode: String {
    case cpu
    case metal
}

private actor WhisperAccelerationCache {
    static let shared = WhisperAccelerationCache()

    private var disabledMetalExecutions = Set<String>()

    func shouldAvoidMetal(for key: String) -> Bool {
        disabledMetalExecutions.contains(key)
    }

    func markMetalFailed(for key: String) {
        disabledMetalExecutions.insert(key)
    }
}

private struct MLXTranscriptionEnvelope: Codable {
    let text: String
    let language: String?
}

public struct MLXWhisperProvider: STTProviding {
    public let providerName = "mlx-whisper"

    private let configuration: STTConfiguration
    private let processRunner: ProcessRunning

    public init(
        configuration: STTConfiguration,
        processRunner: ProcessRunning = DefaultProcessRunner()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
    }

    public func transcribeDemoUtterance() async throws -> String {
        "请把 OpenClaw 的部署文档发给 Horizon Client 团队。"
    }

    public func transcribeAudioFile(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw STTProviderError.audioFileNotFound(fileURL.path)
        }

        guard let pythonPath = configuration.mlxPythonPath, !pythonPath.isEmpty else {
            throw STTProviderError.missingMLXPythonPath
        }

        guard let mlxModel = configuration.mlxModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mlxModel.isEmpty else {
            throw STTProviderError.missingMLXModel
        }

        let runnerScript = RuntimePaths.resolveReadableAppRelativePath("scripts/mlx_transcribe.py")
        guard FileManager.default.fileExists(atPath: runnerScript) else {
            throw STTProviderError.missingMLXRunnerScript
        }

        var arguments = [
            runnerScript,
            "--audio", fileURL.path,
            "--model", mlxModel,
        ]

        let candidateLanguages = candidateLanguages(from: configuration.localeHints)
        if candidateLanguages.count > 1 {
            arguments.append(contentsOf: ["--candidate-languages", candidateLanguages.joined(separator: ",")])
        } else {
            let language = languageArgument(from: configuration.localeHints)
            if language != "auto" {
                arguments.append(contentsOf: ["--language", language])
            }
        }

        if let promptArgument = promptArgument() {
            arguments.append(contentsOf: ["--prompt", promptArgument])
        }

        let result: ProcessResult
        if let cancellableRunner = processRunner as? any CancellableProcessRunning {
            result = try await runShortTranscriptionProcess(
                executable: pythonPath,
                arguments: arguments,
                cancellableRunner: cancellableRunner
            )
        } else {
            result = try processRunner.run(executable: pythonPath, arguments: arguments)
        }

        guard result.exitCode == 0 else {
            throw STTProviderError.commandFailed(result.exitCode, result.combinedOutput)
        }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8) else {
            throw STTProviderError.invalidMLXResponse(output)
        }

        let decoder = JSONDecoder()
        let envelope: MLXTranscriptionEnvelope
        do {
            envelope = try decoder.decode(MLXTranscriptionEnvelope.self, from: data)
        } catch {
            throw STTProviderError.invalidMLXResponse(output)
        }

        return try TranscriptSanitizer.finalizedTranscript(
            from: envelope.text,
            promptInstruction: normalizedPromptInstruction()
        )
    }

    private func languageArgument(from localeHints: [String]) -> String {
        guard !localeHints.isEmpty else {
            return "auto"
        }

        let families = Set(localeHints.map { locale in
            let normalized = locale.lowercased()
            if normalized.hasPrefix("zh") {
                return "zh"
            }
            if normalized.hasPrefix("en") {
                return "en"
            }
            return "auto"
        })

        if families.count != 1 {
            return "auto"
        }

        return families.first ?? "auto"
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

    private func promptArgument() -> String? {
        let promptLines = promptLines()
        guard !promptLines.isEmpty else {
            return nil
        }
        return promptLines.joined(separator: "\n")
    }

    private func promptLines() -> [String] {
        var lines: [String] = []
        if let promptInstruction = normalizedPromptInstruction() {
            lines.append(promptInstruction)
        }
        lines.append(contentsOf: configuration.promptTerms)
        return lines
    }

    private func normalizedPromptInstruction() -> String? {
        guard let promptInstruction = configuration.promptInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !promptInstruction.isEmpty else {
            return nil
        }
        return promptInstruction
    }
}

public final class AppleSpeechProvider: STTProviding, @unchecked Sendable {
    public let providerName = "apple-speech"

    private let configuration: STTConfiguration

    public init(configuration: STTConfiguration) {
        self.configuration = configuration
    }

    public func transcribeDemoUtterance() async throws -> String {
        "请把 OpenClaw 的部署文档发给 Horizon Client 团队。"
    }

    public func transcribeAudioFile(at fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw STTProviderError.audioFileNotFound(fileURL.path)
        }

        let authStatus = await ensureSpeechAuthorization()
        guard authStatus == .authorized else {
            throw STTProviderError.speechRecognitionUnauthorized(speechAuthorizationLabel(authStatus))
        }

        let locale = Locale(identifier: configuration.localeHints.first ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw STTProviderError.speechRecognizerUnavailable("No recognizer is available for locale \(locale.identifier).")
        }

        guard recognizer.isAvailable else {
            throw STTProviderError.speechRecognizerUnavailable("macOS Speech is currently unavailable.")
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.contextualStrings = configuration.promptTerms

        return try await withCheckedThrowingContinuation { continuation in
            let state = ContinuationState(continuation: continuation)
            var recognitionTask: SFSpeechRecognitionTask?
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    recognitionTask?.cancel()
                    recognitionTask = nil
                    state.resume(throwing: STTProviderError.transcriptionFailed(error.localizedDescription))
                    return
                }

                guard let result else {
                    return
                }

                guard result.isFinal else {
                    return
                }

                let transcript = result.bestTranscription.formattedString
                recognitionTask?.finish()
                recognitionTask = nil

                do {
                    state.resume(returning: try TranscriptSanitizer.finalizedTranscript(
                        from: transcript,
                        promptInstruction: self.configuration.promptInstruction
                    ))
                } catch {
                    state.resume(throwing: error)
                }
            }
        }
    }

    private func speechAuthorizationLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    private func ensureSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            return status
        }

        return await Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { updatedStatus in
                    continuation.resume(returning: updatedStatus)
                }
            }
        }.value
    }
}

public enum STTProviderFactory {
    public static func resolveConfiguration(
        _ configuration: STTConfiguration,
        autodiscoverer: STTAutodiscoverer = STTAutodiscoverer()
    ) -> STTConfiguration {
        switch configuration.mode {
        case .appleSpeech, .cloudBackup:
            return configuration
        case .localWhisper:
            if configuration.acceleration == .mlx {
                return resolvedMLXConfiguration(configuration, autodiscoverer: autodiscoverer)
            }
            return resolvedWhisperConfiguration(configuration, autodiscoverer: autodiscoverer)
        case .automaticLocal:
            if configuration.acceleration == .mlx {
                let resolvedMLX = resolvedMLXConfiguration(configuration, autodiscoverer: autodiscoverer)
                if hasUsableMLXConfiguration(resolvedMLX) {
                    return resolvedMLX
                }
            }

            let resolvedWhisper = resolvedWhisperConfiguration(configuration, autodiscoverer: autodiscoverer)
            if let binaryPath = resolvedWhisper.binaryPath, !binaryPath.isEmpty,
               let modelPath = resolvedWhisper.modelPath, !modelPath.isEmpty {
                return resolvedWhisper
            }

            return configuration
        }
    }

    public static func makeProvider(
        configuration: STTConfiguration,
        autodiscoverer: STTAutodiscoverer = STTAutodiscoverer(),
        processRunner: ProcessRunning = DefaultProcessRunner()
    ) throws -> any STTProviding {
        switch configuration.mode {
        case .appleSpeech:
            return AppleSpeechProvider(configuration: configuration)
        case .localWhisper:
            if configuration.acceleration == .mlx {
                return MLXWhisperProvider(
                    configuration: resolvedMLXConfiguration(configuration, autodiscoverer: autodiscoverer),
                    processRunner: processRunner
                )
            }
            return LocalWhisperProvider(
                configuration: resolvedWhisperConfiguration(configuration, autodiscoverer: autodiscoverer),
                processRunner: processRunner
            )
        case .automaticLocal:
            if configuration.acceleration == .mlx {
                let resolvedMLX = resolvedMLXConfiguration(configuration, autodiscoverer: autodiscoverer)
                if hasUsableMLXConfiguration(resolvedMLX) {
                    return MLXWhisperProvider(configuration: resolvedMLX, processRunner: processRunner)
                }
            }

            let resolved = resolvedWhisperConfiguration(configuration, autodiscoverer: autodiscoverer)
            if let binaryPath = resolved.binaryPath, !binaryPath.isEmpty,
               let modelPath = resolved.modelPath, !modelPath.isEmpty {
                return LocalWhisperProvider(configuration: resolved, processRunner: processRunner)
            }
            return AppleSpeechProvider(configuration: configuration)
        case .cloudBackup:
            throw STTProviderError.unsupportedMode(configuration.mode.rawValue)
        }
    }

    private static func resolvedWhisperConfiguration(
        _ configuration: STTConfiguration,
        autodiscoverer: STTAutodiscoverer
    ) -> STTConfiguration {
        let discovery = autodiscoverer.discover()
        let resolvedBinaryPath = RuntimePaths.resolveReadableAppRelativePath(
            configuration.binaryPath ?? discovery.binaryPath ?? ""
        )
        let resolvedModelPath = RuntimePaths.resolveReadableAppRelativePath(
            configuration.modelPath ?? discovery.modelPath ?? ""
        )
        return configuration.updating(
            binaryPath: resolvedBinaryPath.isEmpty ? nil : resolvedBinaryPath,
            modelPath: resolvedModelPath.isEmpty ? nil : resolvedModelPath
        )
    }

    private static func resolvedMLXConfiguration(
        _ configuration: STTConfiguration,
        autodiscoverer: STTAutodiscoverer
    ) -> STTConfiguration {
        let discovery = autodiscoverer.discover()
        let resolvedPythonPath = RuntimePaths.resolveReadableAppRelativePath(
            configuration.mlxPythonPath ?? discovery.mlxPythonPath ?? ""
        )

        let resolvedModel: String?
        if let configuredModel = configuration.mlxModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredModel.isEmpty {
            let maybeResolvedPath = RuntimePaths.resolveReadableAppRelativePath(configuredModel)
            if FileManager.default.fileExists(atPath: maybeResolvedPath) {
                resolvedModel = maybeResolvedPath
            } else {
                resolvedModel = configuredModel
            }
        } else {
            resolvedModel = nil
        }

        return configuration.updating(
            mlxPythonPath: .some(resolvedPythonPath.isEmpty ? nil : resolvedPythonPath),
            mlxModel: .some(resolvedModel)
        )
    }

    private static func hasUsableMLXConfiguration(_ configuration: STTConfiguration) -> Bool {
        guard let pythonPath = configuration.mlxPythonPath, !pythonPath.isEmpty,
              let mlxModel = configuration.mlxModel, !mlxModel.isEmpty else {
            return false
        }

        return FileManager.default.isExecutableFile(atPath: pythonPath) && !mlxModel.isEmpty
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> ProcessResult
}

public protocol CancellableProcessRunning: ProcessRunning {
    func runCancellable(executable: String, arguments: [String]) async throws -> ProcessResult
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct DefaultProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: stdoutData, as: UTF8.self),
            standardError: String(decoding: stderrData, as: UTF8.self)
        )
    }
}

extension DefaultProcessRunner: CancellableProcessRunning {
    public func runCancellable(executable: String, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = ProcessContinuationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)

                process.terminationHandler = { terminatedProcess in
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    state.resume(
                        returning: ProcessResult(
                            exitCode: terminatedProcess.terminationStatus,
                            standardOutput: String(decoding: stdoutData, as: UTF8.self),
                            standardError: String(decoding: stderrData, as: UTF8.self)
                        )
                    )
                }

                do {
                    try process.run()
                } catch {
                    state.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private let shortTranscriptionTimeoutSeconds = 45

private func runShortTranscriptionProcess(
    executable: String,
    arguments: [String],
    cancellableRunner: any CancellableProcessRunning
) async throws -> ProcessResult {
    try await withThrowingTaskGroup(of: ProcessResult.self) { group in
        group.addTask {
            try await cancellableRunner.runCancellable(executable: executable, arguments: arguments)
        }
        group.addTask {
            try await Task.sleep(for: .seconds(shortTranscriptionTimeoutSeconds))
            throw STTProviderError.transcriptionTimedOut(shortTranscriptionTimeoutSeconds)
        }

        guard let result = try await group.next() else {
            group.cancelAll()
            throw STTProviderError.transcriptionTimedOut(shortTranscriptionTimeoutSeconds)
        }
        group.cancelAll()
        return result
    }
}

private final class ContinuationState {
    private let lock = NSLock()
    private var hasResumed = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else {
            return
        }
        hasResumed = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else {
            return
        }
        hasResumed = true
        continuation.resume(throwing: error)
    }
}

private final class ProcessContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    func setContinuation(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(returning value: ProcessResult) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed, let continuation else {
            return
        }
        hasResumed = true
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed, let continuation else {
            return
        }
        hasResumed = true
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}
