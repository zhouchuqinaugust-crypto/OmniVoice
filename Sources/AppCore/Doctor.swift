import AVFoundation
import ApplicationServices
import Foundation
import Speech

public enum DiagnosticStatus: String, Codable, Sendable {
    case pass
    case warning
    case fail
}

public struct DiagnosticItem: Codable, Sendable {
    public let name: String
    public let status: DiagnosticStatus
    public let message: String

    public init(name: String, status: DiagnosticStatus, message: String) {
        self.name = name
        self.status = status
        self.message = message
    }
}

public struct DoctorReport: Codable, Sendable {
    public let generatedAt: Date
    public let items: [DiagnosticItem]

    public init(generatedAt: Date = .now, items: [DiagnosticItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }
}

public struct AppDoctor {
    private let configuration: AppConfiguration
    private let processRunner: ProcessRunning
    private let fileManager: FileManager
    private let environment: [String: String]
    private let sttAutodiscoverer: STTAutodiscoverer
    private let keychainStore: KeychainStoring

    public init(
        configuration: AppConfiguration,
        processRunner: ProcessRunning = DefaultProcessRunner(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sttAutodiscoverer: STTAutodiscoverer = STTAutodiscoverer(),
        keychainStore: KeychainStoring = SystemKeychainStore()
    ) {
        self.configuration = configuration
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.environment = environment
        self.sttAutodiscoverer = sttAutodiscoverer
        self.keychainStore = keychainStore
    }

    public func run() -> DoctorReport {
        DoctorReport(
            items: [
                microphoneItem(),
                speechRecognitionItem(),
                accessibilityItem(),
                automationItem(),
                sttBinaryItem(),
                sttModelItem(),
                sttAccelerationItem(),
                askAPIKeyItem(),
                dictionaryItem(),
            ]
        )
    }

    private func microphoneItem() -> DiagnosticItem {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return DiagnosticItem(name: "Microphone", status: .pass, message: "Microphone access is authorized.")
        case .notDetermined:
            return DiagnosticItem(name: "Microphone", status: .warning, message: "Microphone access has not been requested yet.")
        case .denied, .restricted:
            return DiagnosticItem(name: "Microphone", status: .fail, message: "Microphone access is unavailable. Dictation will not work until this is granted in System Settings.")
        @unknown default:
            return DiagnosticItem(name: "Microphone", status: .warning, message: "Microphone permission status is unknown.")
        }
    }

    private func speechRecognitionItem() -> DiagnosticItem {
        if hasUsableLocalSTTConfiguration() {
            return DiagnosticItem(name: "Speech Recognition", status: .pass, message: "A local STT backend is configured and available. Apple Speech permission is not required.")
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return DiagnosticItem(name: "Speech Recognition", status: .pass, message: "Speech recognition access is authorized.")
        case .notDetermined:
            let detail = configuration.stt.mode == .automaticLocal
                ? "Speech recognition access has not been requested yet. Apple Speech fallback will stay unavailable until it is granted."
                : "Speech recognition access has not been requested yet."
            return DiagnosticItem(name: "Speech Recognition", status: .warning, message: detail)
        case .denied, .restricted:
            let detail = configuration.stt.mode == .automaticLocal
                ? "Speech recognition access is unavailable. Apple Speech fallback will not work until this is granted in System Settings."
                : "Speech recognition access is unavailable."
            return DiagnosticItem(name: "Speech Recognition", status: .fail, message: detail)
        @unknown default:
            return DiagnosticItem(name: "Speech Recognition", status: .warning, message: "Speech recognition permission status is unknown.")
        }
    }

    private func accessibilityItem() -> DiagnosticItem {
        if AXIsProcessTrusted() {
            return DiagnosticItem(name: "Accessibility", status: .pass, message: "Accessibility permission is currently available.")
        }

        return DiagnosticItem(name: "Accessibility", status: .fail, message: "Accessibility permission is not granted. Text insertion and selected-text capture will fail until it is enabled.")
    }

    private func automationItem() -> DiagnosticItem {
        if AXIsProcessTrusted() {
            return DiagnosticItem(name: "Automation", status: .pass, message: "Native keyboard input injection is available through Accessibility.")
        }

        return DiagnosticItem(name: "Automation", status: .fail, message: "Accessibility permission is not granted. Paste and selected-text capture will fail until it is enabled.")
    }

    private func sttBinaryItem() -> DiagnosticItem {
        let autodiscovery = sttAutodiscoverer.discover()

        if configuration.stt.mode == .appleSpeech {
            return DiagnosticItem(name: "Local STT Binary", status: .pass, message: "STT mode is Apple Speech. No external whisper binary is required.")
        }

        if configuration.stt.acceleration == .mlx {
            guard let path = configuration.stt.mlxPythonPath, !path.isEmpty else {
                if let suggestedPath = autodiscovery.mlxPythonPath {
                    return DiagnosticItem(
                        name: "Local STT Binary",
                        status: .warning,
                        message: "No MLX Python runtime path is configured. Detected candidate: \(suggestedPath)"
                    )
                }

                return DiagnosticItem(
                    name: "Local STT Binary",
                    status: .warning,
                    message: "No MLX Python runtime path is configured."
                )
            }

            let resolvedPath = RuntimePaths.resolveReadableAppRelativePath(path, fileManager: fileManager, environment: environment)
            if fileManager.isExecutableFile(atPath: resolvedPath) {
                return DiagnosticItem(name: "Local STT Binary", status: .pass, message: "Found executable MLX Python runtime at \(resolvedPath).")
            }

            let suffix = autodiscovery.mlxPythonPath.map { " Suggested candidate: \($0)" } ?? ""
            return DiagnosticItem(name: "Local STT Binary", status: .fail, message: "Configured MLX Python runtime is missing or not executable: \(resolvedPath)\(suffix)")
        }

        guard let path = configuration.stt.binaryPath, !path.isEmpty else {
            if let suggestedPath = autodiscovery.binaryPath {
                let fallbackMessage = configuration.stt.mode == .automaticLocal ? " Apple Speech fallback will be used until a whisper binary is configured." : ""
                return DiagnosticItem(
                    name: "Local STT Binary",
                    status: .warning,
                    message: "No local STT binary path is configured. Detected candidate: \(suggestedPath)\(fallbackMessage)"
                )
            }

            let fallbackMessage = configuration.stt.mode == .automaticLocal ? " Apple Speech fallback will be used until a whisper binary is configured." : ""
            return DiagnosticItem(name: "Local STT Binary", status: .warning, message: "No local STT binary path is configured.\(fallbackMessage)")
        }

        let resolvedPath = RuntimePaths.resolveReadableAppRelativePath(path, fileManager: fileManager, environment: environment)
        if fileManager.isExecutableFile(atPath: resolvedPath) {
            return DiagnosticItem(name: "Local STT Binary", status: .pass, message: "Found executable local STT binary at \(resolvedPath).")
        }

        let suffix = autodiscovery.binaryPath.map { " Suggested candidate: \($0)" } ?? ""
        return DiagnosticItem(name: "Local STT Binary", status: .fail, message: "Configured STT binary is missing or not executable: \(resolvedPath)\(suffix)")
    }

    private func sttModelItem() -> DiagnosticItem {
        let autodiscovery = sttAutodiscoverer.discover()

        if configuration.stt.mode == .appleSpeech {
            return DiagnosticItem(name: "Local STT Model", status: .pass, message: "STT mode is Apple Speech. No external whisper model is required.")
        }

        if configuration.stt.acceleration == .mlx {
            guard let model = configuration.stt.mlxModel, !trimmed(model).isEmpty else {
                return DiagnosticItem(
                    name: "Local STT Model",
                    status: .warning,
                    message: "No MLX model repo or local path is configured."
                )
            }

            let resolvedPath = RuntimePaths.resolveReadableAppRelativePath(model, fileManager: fileManager, environment: environment)
            if fileManager.fileExists(atPath: resolvedPath) {
                return DiagnosticItem(name: "Local STT Model", status: .pass, message: "Found local MLX model at \(resolvedPath).")
            }

            return DiagnosticItem(name: "Local STT Model", status: .pass, message: "MLX model repo is configured as \(model). It will be downloaded on first use if not cached locally.")
        }

        guard let path = configuration.stt.modelPath, !path.isEmpty else {
            if let suggestedPath = autodiscovery.modelPath {
                let fallbackMessage = configuration.stt.mode == .automaticLocal ? " Apple Speech fallback will be used until a whisper model is configured." : ""
                return DiagnosticItem(
                    name: "Local STT Model",
                    status: .warning,
                    message: "No local STT model path is configured. Detected candidate: \(suggestedPath)\(fallbackMessage)"
                )
            }

            let fallbackMessage = configuration.stt.mode == .automaticLocal ? " Apple Speech fallback will be used until a whisper model is configured." : ""
            return DiagnosticItem(name: "Local STT Model", status: .warning, message: "No local STT model path is configured.\(fallbackMessage)")
        }

        let resolvedPath = RuntimePaths.resolveReadableAppRelativePath(path, fileManager: fileManager, environment: environment)
        if fileManager.fileExists(atPath: resolvedPath) {
            return DiagnosticItem(name: "Local STT Model", status: .pass, message: "Found local STT model at \(resolvedPath).")
        }

        let suffix = autodiscovery.modelPath.map { " Suggested candidate: \($0)" } ?? ""
        return DiagnosticItem(name: "Local STT Model", status: .fail, message: "Configured STT model file does not exist: \(resolvedPath)\(suffix)")
    }

    private func sttAccelerationItem() -> DiagnosticItem {
        let threadDescription = configuration.stt.threadCount.map { String($0) } ?? "auto"

        switch configuration.stt.acceleration {
        case .cpu:
            return DiagnosticItem(
                name: "STT Acceleration",
                status: .pass,
                message: "Local whisper.cpp is pinned to CPU mode. Whisper threads: \(threadDescription)."
            )
        case .auto:
            return DiagnosticItem(
                name: "STT Acceleration",
                status: .warning,
                message: "Local whisper.cpp is set to Auto acceleration. It will try Metal first and fall back to CPU if the GPU path fails. Whisper threads: \(threadDescription)."
            )
        case .metal:
            return DiagnosticItem(
                name: "STT Acceleration",
                status: .warning,
                message: "Local whisper.cpp is pinned to experimental Metal acceleration. If transcription crashes on this machine, switch this back to CPU or Auto. Whisper threads: \(threadDescription)."
            )
        case .mlx:
            return DiagnosticItem(
                name: "STT Acceleration",
                status: .pass,
                message: "Local STT is pinned to MLX Whisper. The Python runtime and MLX model repo/path must both be configured."
            )
        }
    }

    private func askAPIKeyItem() -> DiagnosticItem {
        let keyName = configuration.ask.apiKeyEnvironmentVariable
        if let value = environment[keyName], !value.isEmpty {
            return DiagnosticItem(name: "Ask API Key", status: .pass, message: "Environment variable \(keyName) is set.")
        }

        if let service = configuration.ask.keychainService,
           let account = configuration.ask.keychainAccount {
            if let storedValue = try? keychainStore.readPassword(service: service, account: account),
               !storedValue.isEmpty {
                return DiagnosticItem(name: "Ask API Key", status: .pass, message: "Ask API key is stored in Keychain for \(service)/\(account).")
            }
        }

        return DiagnosticItem(name: "Ask API Key", status: .warning, message: "Environment variable \(keyName) is not set. Ask Anything will fall back to the mock provider.")
    }

    private func dictionaryItem() -> DiagnosticItem {
        guard let path = configuration.dictionary.filePath, !path.isEmpty else {
            return DiagnosticItem(name: "Dictionary File", status: .warning, message: "No external dictionary file is configured.")
        }

        if fileManager.fileExists(atPath: path) {
            return DiagnosticItem(name: "Dictionary File", status: .pass, message: "External dictionary file exists at \(path).")
        }

        return DiagnosticItem(name: "Dictionary File", status: .warning, message: "External dictionary file is missing, inline entries will be used instead.")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasUsableLocalSTTConfiguration() -> Bool {
        if configuration.stt.acceleration == .mlx {
            guard let pythonPath = configuration.stt.mlxPythonPath, !pythonPath.isEmpty,
                  let model = configuration.stt.mlxModel, !trimmed(model).isEmpty else {
                return false
            }

            let resolvedPythonPath = RuntimePaths.resolveReadableAppRelativePath(pythonPath, fileManager: fileManager, environment: environment)
            return fileManager.isExecutableFile(atPath: resolvedPythonPath)
        }

        guard let binaryPath = configuration.stt.binaryPath, !binaryPath.isEmpty,
              let modelPath = configuration.stt.modelPath, !modelPath.isEmpty else {
            return false
        }

        let resolvedBinaryPath = RuntimePaths.resolveReadableAppRelativePath(binaryPath, fileManager: fileManager, environment: environment)
        let resolvedModelPath = RuntimePaths.resolveReadableAppRelativePath(modelPath, fileManager: fileManager, environment: environment)
        return fileManager.isExecutableFile(atPath: resolvedBinaryPath) && fileManager.fileExists(atPath: resolvedModelPath)
    }
}
