import Foundation

public extension STTConfiguration {
    func updating(
        mode: STTMode? = nil,
        binaryPath: String? = nil,
        modelPath: String? = nil,
        promptInstruction: String?? = nil,
        promptTerms: [String]? = nil,
        acceleration: STTAccelerationMode? = nil,
        threadCount: Int?? = nil,
        mlxPythonPath: String?? = nil,
        mlxModel: String?? = nil
    ) -> STTConfiguration {
        STTConfiguration(
            mode: mode ?? self.mode,
            localeHints: localeHints,
            binaryPath: binaryPath ?? self.binaryPath,
            modelPath: modelPath ?? self.modelPath,
            promptInstruction: promptInstruction ?? self.promptInstruction,
            promptTerms: promptTerms ?? self.promptTerms,
            acceleration: acceleration ?? self.acceleration,
            threadCount: threadCount ?? self.threadCount,
            mlxPythonPath: mlxPythonPath ?? self.mlxPythonPath,
            mlxModel: mlxModel ?? self.mlxModel
        )
    }
}

public extension AskConfiguration {
    func updating(
        baseURL: String? = nil,
        defaultModel: String? = nil,
        apiKeyEnvironmentVariable: String? = nil,
        keychainService: String? = nil,
        keychainAccount: String? = nil
    ) -> AskConfiguration {
        AskConfiguration(
            provider: provider,
            baseURL: baseURL ?? self.baseURL,
            defaultModel: defaultModel ?? self.defaultModel,
            apiKeyEnvironmentVariable: apiKeyEnvironmentVariable ?? self.apiKeyEnvironmentVariable,
            keychainService: keychainService ?? self.keychainService,
            keychainAccount: keychainAccount ?? self.keychainAccount,
            supportsImageContext: supportsImageContext,
            systemPrompt: systemPrompt
        )
    }
}

public extension AppConfiguration {
    func updatingSTT(
        mode: STTMode? = nil,
        binaryPath: String? = nil,
        modelPath: String? = nil,
        promptInstruction: String?? = nil,
        promptTerms: [String]? = nil,
        acceleration: STTAccelerationMode? = nil,
        threadCount: Int?? = nil,
        mlxPythonPath: String?? = nil,
        mlxModel: String?? = nil
    ) -> AppConfiguration {
        AppConfiguration(
            appName: appName,
            stt: stt.updating(
                mode: mode,
                binaryPath: binaryPath,
                modelPath: modelPath,
                promptInstruction: promptInstruction,
                promptTerms: promptTerms,
                acceleration: acceleration,
                threadCount: threadCount,
                mlxPythonPath: mlxPythonPath,
                mlxModel: mlxModel
            ),
            ask: ask,
            dictionary: dictionary,
            insertion: insertion,
            hotkeys: hotkeys
        )
    }

    func updatingDictionary(entries: [DictionaryEntry], filePath: String? = nil) -> AppConfiguration {
        AppConfiguration(
            appName: appName,
            stt: stt,
            ask: ask,
            dictionary: DictionaryConfiguration(
                entries: entries,
                filePath: filePath ?? dictionary.filePath
            ),
            insertion: insertion,
            hotkeys: hotkeys
        )
    }

    func updatingAsk(
        baseURL: String? = nil,
        defaultModel: String? = nil,
        apiKeyEnvironmentVariable: String? = nil,
        keychainService: String? = nil,
        keychainAccount: String? = nil
    ) -> AppConfiguration {
        AppConfiguration(
            appName: appName,
            stt: stt,
            ask: ask.updating(
                baseURL: baseURL,
                defaultModel: defaultModel,
                apiKeyEnvironmentVariable: apiKeyEnvironmentVariable,
                keychainService: keychainService,
                keychainAccount: keychainAccount
            ),
            dictionary: dictionary,
            insertion: insertion,
            hotkeys: hotkeys
        )
    }
}
