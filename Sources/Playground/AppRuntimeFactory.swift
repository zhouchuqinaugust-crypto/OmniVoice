import AppCore
import Foundation

enum RuntimeFactory {
    static func makeCoordinator(
        configuration: AppConfiguration,
        loader: ConfigurationLoader = ConfigurationLoader()
    ) throws -> AppCoordinator {
        let preparedSTTRuntime = try prepareSTTRuntime(
            configuration: configuration,
            loader: loader
        )
        let sttProvider = try STTProviderFactory.makeProvider(
            configuration: preparedSTTRuntime.sttConfiguration
        )
        let askProvider: any AskProviding

        do {
            askProvider = try AskProviderFactory.makeProvider(
                configuration: configuration.ask,
                applicationName: configuration.appName
            )
        } catch AskProviderError.missingAPIKey {
            askProvider = MockAskProvider()
        }

        return AppCoordinator(
            sttProvider: sttProvider,
            askProvider: askProvider,
            dictionaryEngine: preparedSTTRuntime.dictionaryEngine,
            insertionEngine: InsertionEngine(configuration: configuration.insertion)
        )
    }

    static func makeAudioFileTranscriptionExporter(
        configuration: AppConfiguration,
        loader: ConfigurationLoader = ConfigurationLoader()
    ) throws -> AudioFileTranscriptionExporter {
        let preparedSTTRuntime = try prepareSTTRuntime(
            configuration: configuration,
            loader: loader
        )
        let sttProvider = try STTProviderFactory.makeProvider(configuration: preparedSTTRuntime.sttConfiguration)
        return AudioFileTranscriptionExporter(
            sttConfiguration: STTProviderFactory.resolveConfiguration(preparedSTTRuntime.sttConfiguration),
            sttProvider: sttProvider,
            dictionaryEngine: preparedSTTRuntime.dictionaryEngine
        )
    }

    private static func prepareSTTRuntime(
        configuration: AppConfiguration,
        loader: ConfigurationLoader
    ) throws -> PreparedSTTRuntime {
        let chineseScriptPreference = ChineseScriptPreference.fromPreferredLanguages()

        let dictionaryEntries: [DictionaryEntry]
        do {
            dictionaryEntries = try loader.resolvedDictionaryEntries(for: configuration)
        } catch {
            dictionaryEntries = configuration.dictionary.entries
        }

        let promptInstruction = normalizedPromptInstruction(
            configuration.stt.promptInstruction
        ) ?? chineseScriptPreference.whisperPromptInstruction

        var sttPromptTerms: [String] = []
        sttPromptTerms.append(contentsOf: configuration.stt.promptTerms)
        sttPromptTerms.append(contentsOf: dictionaryEntries.map(\.target))
        sttPromptTerms = deduplicated(sttPromptTerms)

        let sttConfiguration = configuration.updatingSTT(
            promptInstruction: .some(promptInstruction),
            promptTerms: sttPromptTerms
        ).stt

        return PreparedSTTRuntime(
            sttConfiguration: sttConfiguration,
            dictionaryEngine: DictionaryEngine(
                entries: dictionaryEntries,
                chineseScriptPreference: chineseScriptPreference
            )
        )
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty, !seen.contains(value) else {
                return false
            }
            seen.insert(value)
            return true
        }
    }

    private static func normalizedPromptInstruction(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct PreparedSTTRuntime {
    let sttConfiguration: STTConfiguration
    let dictionaryEngine: DictionaryEngine
}
