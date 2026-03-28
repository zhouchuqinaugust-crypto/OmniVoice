import AppCore
import Foundation

enum RuntimeFactory {
    static func makeCoordinator(
        configuration: AppConfiguration,
        loader: ConfigurationLoader = ConfigurationLoader()
    ) throws -> AppCoordinator {
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
        let sttProvider = try STTProviderFactory.makeProvider(configuration: sttConfiguration)
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
            dictionaryEngine: DictionaryEngine(
                entries: dictionaryEntries,
                chineseScriptPreference: chineseScriptPreference
            ),
            insertionEngine: InsertionEngine(configuration: configuration.insertion)
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
