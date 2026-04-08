import Foundation

public enum ConfigurationLoaderError: LocalizedError, Sendable {
    case invalidPath(String)
    case invalidConfiguration(String, [String])
    case unableToRead(String, Error)
    case unableToDecode(String, Error)
    case unableToEncode(String, Error)
    case unableToWrite(String, Error)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Invalid configuration path: \(path)"
        case .invalidConfiguration(let path, let messages):
            return "Invalid configuration at \(path): \(messages.joined(separator: "; "))"
        case .unableToRead(let path, let error):
            return "Unable to read configuration at \(path): \(error.localizedDescription)"
        case .unableToDecode(let path, let error):
            return "Unable to decode configuration at \(path): \(error.localizedDescription)"
        case .unableToEncode(let path, let error):
            return "Unable to encode configuration for \(path): \(error.localizedDescription)"
        case .unableToWrite(let path, let error):
            return "Unable to write configuration to \(path): \(error.localizedDescription)"
        }
    }
}

public struct ConfigurationLoader {
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fileManager = fileManager
        self.decoder = decoder
    }

    public func load(
        fromExplicitPath explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppConfiguration {
        if let path = resolvedConfigPath(explicitPath: explicitPath, environment: environment),
           fileManager.fileExists(atPath: path) {
            return try decodeAppConfiguration(at: path)
        }

        if explicitPath == nil,
           let bundledConfigPath = RuntimePaths.bundledConfigPath(),
           fileManager.fileExists(atPath: bundledConfigPath) {
            return try decodeAppConfiguration(at: bundledConfigPath)
        }

        return AppConfiguration.sample()
    }

    public func resolvedConfigPath(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicitPath, !explicitPath.isEmpty {
            return explicitPath
        }

        return RuntimePaths.defaultConfigPath(fileManager: fileManager, environment: environment)
    }

    public func save(_ configuration: AppConfiguration, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let url = URL(fileURLWithPath: path)

        do {
            let data = try encoder.encode(configuration)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAtomically(data, to: url)
        } catch let error as EncodingError {
            throw ConfigurationLoaderError.unableToEncode(path, error)
        } catch {
            throw ConfigurationLoaderError.unableToWrite(path, error)
        }
    }

    public func saveDictionaryEntries(_ entries: [DictionaryEntry], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let resolvedPath = RuntimePaths.resolveWritableAppRelativePath(
            path,
            fileManager: fileManager
        )
        let url = URL(fileURLWithPath: resolvedPath)

        do {
            let data = try encoder.encode(entries)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeAtomically(data, to: url)
        } catch let error as EncodingError {
            throw ConfigurationLoaderError.unableToEncode(resolvedPath, error)
        } catch {
            throw ConfigurationLoaderError.unableToWrite(resolvedPath, error)
        }
    }

    public func resolvedDictionaryEntries(
        for configuration: AppConfiguration
    ) throws -> [DictionaryEntry] {
        guard let filePath = configuration.dictionary.filePath, !filePath.isEmpty else {
            return configuration.dictionary.entries
        }

        let resolvedPath = RuntimePaths.resolveReadableAppRelativePath(
            filePath,
            fileManager: fileManager
        )

        guard fileManager.fileExists(atPath: resolvedPath) else {
            return configuration.dictionary.entries
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
            return try decoder.decode([DictionaryEntry].self, from: data)
        } catch let error as DecodingError {
            throw ConfigurationLoaderError.unableToDecode(resolvedPath, error)
        } catch {
            throw ConfigurationLoaderError.unableToRead(resolvedPath, error)
        }
    }

    private func decodeAppConfiguration(at path: String) throws -> AppConfiguration {
        let url = URL(fileURLWithPath: path)
        guard !path.isEmpty else {
            throw ConfigurationLoaderError.invalidPath(path)
        }

        do {
            let data = try Data(contentsOf: url)
            let configuration = try decoder.decode(AppConfiguration.self, from: data)
            let validationErrors = validate(configuration)
            guard validationErrors.isEmpty else {
                throw ConfigurationLoaderError.invalidConfiguration(path, validationErrors)
            }
            return configuration
        } catch let error as DecodingError {
            throw ConfigurationLoaderError.unableToDecode(path, error)
        } catch let error as ConfigurationLoaderError {
            throw error
        } catch {
            throw ConfigurationLoaderError.unableToRead(path, error)
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let backupURL = url.appendingPathExtension("bak")

        try data.write(to: temporaryURL, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: url, to: backupURL)
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }
    }

    private func validate(_ configuration: AppConfiguration) -> [String] {
        var errors: [String] = []

        if configuration.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("appName must not be empty")
        }

        if let threadCount = configuration.stt.threadCount, threadCount <= 0 {
            errors.append("stt.threadCount must be greater than 0 when set")
        }

        if let binaryPath = configuration.stt.binaryPath, binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("stt.binaryPath must not be an empty string")
        }

        if let modelPath = configuration.stt.modelPath, modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("stt.modelPath must not be an empty string")
        }

        if let mlxPythonPath = configuration.stt.mlxPythonPath, mlxPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("stt.mlxPythonPath must not be an empty string")
        }

        if let mlxModel = configuration.stt.mlxModel, mlxModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("stt.mlxModel must not be an empty string")
        }

        let localDefault = configuration.insertion.localDefault
        let remoteDefault = configuration.insertion.remoteDefault
        for (name, plan) in [("insertion.localDefault", localDefault), ("insertion.remoteDefault", remoteDefault)] {
            if plan.delayMilliseconds < 0 {
                errors.append("\(name).delayMilliseconds must not be negative")
            }
            if plan.attemptCount <= 0 {
                errors.append("\(name).attemptCount must be greater than 0")
            }
            if plan.retryIntervalMilliseconds < 0 {
                errors.append("\(name).retryIntervalMilliseconds must not be negative")
            }
        }

        return errors
    }
}
