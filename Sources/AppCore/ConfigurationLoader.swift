import Foundation

public enum ConfigurationLoaderError: LocalizedError, Sendable {
    case invalidPath(String)
    case unableToRead(String, Error)
    case unableToDecode(String, Error)
    case unableToEncode(String, Error)
    case unableToWrite(String, Error)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Invalid configuration path: \(path)"
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
            try data.write(to: url)
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
            try data.write(to: url)
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
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch let error as DecodingError {
            throw ConfigurationLoaderError.unableToDecode(path, error)
        } catch {
            throw ConfigurationLoaderError.unableToRead(path, error)
        }
    }
}
