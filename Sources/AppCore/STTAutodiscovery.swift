import Foundation

public struct STTAutodiscoveryResult: Codable, Sendable {
    public let binaryPath: String?
    public let modelPath: String?
    public let mlxPythonPath: String?
    public let searchedBinaryPaths: [String]
    public let searchedModelDirectories: [String]
    public let searchedMLXPythonPaths: [String]

    public init(
        binaryPath: String?,
        modelPath: String?,
        mlxPythonPath: String?,
        searchedBinaryPaths: [String],
        searchedModelDirectories: [String],
        searchedMLXPythonPaths: [String]
    ) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.mlxPythonPath = mlxPythonPath
        self.searchedBinaryPaths = searchedBinaryPaths
        self.searchedModelDirectories = searchedModelDirectories
        self.searchedMLXPythonPaths = searchedMLXPythonPaths
    }
}

public struct STTAutodiscoverer {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let currentDirectoryPath: String
    private let includeSensitiveDirectories: Bool

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        includeSensitiveDirectories: Bool = false
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.currentDirectoryPath = currentDirectoryPath
        self.includeSensitiveDirectories = includeSensitiveDirectories
    }

    public func discover() -> STTAutodiscoveryResult {
        let binaryCandidates = possibleBinaryPaths()
        let modelDirectories = possibleModelDirectories()
        let mlxPythonCandidates = possibleMLXPythonPaths()

        return STTAutodiscoveryResult(
            binaryPath: binaryCandidates.first(where: fileManager.isExecutableFile(atPath:)),
            modelPath: discoverModel(in: modelDirectories),
            mlxPythonPath: mlxPythonCandidates.first(where: fileManager.isExecutableFile(atPath:)),
            searchedBinaryPaths: binaryCandidates,
            searchedModelDirectories: modelDirectories,
            searchedMLXPythonPaths: mlxPythonCandidates
        )
    }

    private func possibleBinaryPaths() -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .flatMap { entry -> [String] in
                let base = String(entry)
                return [
                    "\(base)/whisper-cli",
                    "\(base)/whisper",
                ]
            }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let explicit = [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper",
            "\(home)/whisper.cpp/build/bin/whisper-cli",
            "\(home)/whisper.cpp/build/bin/main",
            "\(home)/src/whisper.cpp/build/bin/whisper-cli",
            "\(home)/src/whisper.cpp/build/bin/main",
            "\(home)/Documents/whisper.cpp/build/bin/whisper-cli",
            "\(home)/Documents/whisper.cpp/build/bin/main",
        ]

        return unique(explicit + pathEntries)
    }

    private func possibleModelDirectories() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var directories = [
            "\(currentDirectoryPath)/models",
            "\(home)/Library/Application Support/whisper.cpp/models",
            "\(home)/Library/Application Support/com.ggerganov.whisper/models",
            "\(home)/.cache/whisper",
            "\(home)/Models",
            "\(home)/whisper.cpp/models",
            "\(home)/src/whisper.cpp/models",
            "\(home)/Documents/whisper.cpp/models",
        ]

        if includeSensitiveDirectories {
            directories.append("\(home)/Downloads")
        }

        return unique(directories)
    }

    private func possibleMLXPythonPaths() -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let current = currentDirectoryPath

        let candidates = [
            "\(current)/.venv-mlx/bin/python",
            "\(current)/.venv/bin/python",
            "\(home)/.venv-mlx/bin/python",
            "\(home)/.venv/bin/python",
            "\(home)/miniforge3/envs/mlx/bin/python",
            "\(home)/miniconda3/envs/mlx/bin/python",
            "\(home)/mambaforge/envs/mlx/bin/python",
        ]

        return unique(candidates)
    }

    private func discoverModel(in directories: [String]) -> String? {
        let preferredNames = [
            "ggml-base.bin",
            "ggml-small.bin",
            "ggml-medium.bin",
            "ggml-large-v3.bin",
            "ggml-large-v3-turbo.bin",
        ]

        for directory in directories where fileManager.fileExists(atPath: directory) {
            for fileName in preferredNames {
                let candidate = "\(directory)/\(fileName)"
                if fileManager.fileExists(atPath: candidate) {
                    return candidate
                }
            }

            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }

            let fallback = contents
                .sorted()
                .first { $0.hasPrefix("ggml-") && ($0.hasSuffix(".bin") || $0.hasSuffix(".gguf")) }

            if let fallback {
                return "\(directory)/\(fallback)"
            }
        }

        return nil
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
