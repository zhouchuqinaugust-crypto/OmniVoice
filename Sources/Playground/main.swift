import AppCore
import Foundation

private let command: Command

do {
    command = try Command.parse(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}

if case .ui = command {
    let exitCode = MainActor.assumeIsolated {
        PlaygroundCLI.runUI()
    }
    Foundation.exit(exitCode)
}

enum PlaygroundCLI {
    @MainActor
    static func runUI() -> Int32 {
        do {
            let runtime = try bootstrap()
            MenuBarApplication.run(
                configuration: runtime.configuration,
                coordinator: runtime.coordinator,
                audioFileTranscriptionExporter: runtime.audioFileTranscriptionExporter,
                configPath: runtime.configPath,
                contextResolver: runtime.contextResolver,
                historyStore: runtime.historyStore,
                hotkeys: runtime.configuration.hotkeys
            )
            return 0
        } catch {
            fputs("Failed to configure runtime: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    fileprivate static func run(command: Command) async -> Int32 {
        let runtime: Runtime
        do {
            runtime = try bootstrap()
        } catch {
            fputs("Failed to configure runtime: \(error.localizedDescription)\n", stderr)
            return 1
        }

        do {
            switch command {
            case .demo:
                try await runDemo(coordinator: runtime.coordinator, historyStore: runtime.historyStore)
            case .context(let source):
                try printJSON(runtime.contextResolver.resolve(source: source))
            case .config:
                try printJSON(runtime.configuration)
            case .history:
                try printJSON(runtime.historyStore.recentEvents())
            case .doctor:
                try printJSON(runtime.doctor.run())
            case .autodetectSTT:
                try autodetectSTT(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration
                )
            case .requestPermissions:
                let report = await PermissionManager.requestAll()
                try printJSON(report)
            case .setSTTBinary(let path):
                try setSTTBinary(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    path: path
                )
            case .setSTTModel(let path):
                try setSTTModel(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    path: path
                )
            case .setSTTMode(let mode):
                try setSTTMode(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    mode: mode
                )
            case .setSTTAcceleration(let acceleration):
                try setSTTAcceleration(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    acceleration: acceleration
                )
            case .setSTTThreads(let threadCount):
                try setSTTThreads(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    threadCount: threadCount
                )
            case .setSTTPromptInstruction(let prompt):
                try setSTTPromptInstruction(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    prompt: prompt
                )
            case .clearSTTPromptInstruction:
                try clearSTTPromptInstruction(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration
                )
            case .setMLXPython(let path):
                try setMLXPython(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    path: path
                )
            case .setMLXModel(let model):
                try setMLXModel(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    model: model
                )
            case .setAskModel(let model):
                try setAskModel(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    model: model
                )
            case .setAskBaseURL(let baseURL):
                try setAskBaseURL(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    baseURL: baseURL
                )
            case .setAskAPIKey(let value):
                try setAskAPIKey(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    value: value
                )
            case .clearAskAPIKey:
                try clearAskAPIKey(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration
                )
            case .hotkeys:
                try printJSON(runtime.configuration.hotkeys.summaries())
            case .setHotkey(let action, let shortcut):
                try setHotkey(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    action: action,
                    shortcut: shortcut
                )
            case .disableHotkey(let action):
                try disableHotkey(
                    loader: runtime.loader,
                    configPath: runtime.configPath,
                    configuration: runtime.configuration,
                    action: action
                )
            case .lastTranscript:
                try printJSON(runtime.historyStore.lastTranscript())
            case .lastAnswer:
                try printJSON(runtime.historyStore.lastAnswer())
            case .copyLastTranscript:
                try copyLastTranscript(historyStore: runtime.historyStore, clipboardStore: runtime.clipboardStore)
            case .copyLastAnswer:
                try copyLastAnswer(historyStore: runtime.historyStore, clipboardStore: runtime.clipboardStore)
            case .insertLastTranscript(let source):
                try await insertLastTranscript(
                    historyStore: runtime.historyStore,
                    clipboardStore: runtime.clipboardStore,
                    coordinator: runtime.coordinator,
                    contextResolver: runtime.contextResolver,
                    source: source
                )
            case .insertLastAnswer(let source):
                try await insertLastAnswer(
                    historyStore: runtime.historyStore,
                    clipboardStore: runtime.clipboardStore,
                    coordinator: runtime.coordinator,
                    contextResolver: runtime.contextResolver,
                    source: source
                )
            case .insert(let text, let source):
                let context = try runtime.contextResolver.resolve(source: source)
                let insertionPlan = try await runtime.coordinator.insert(text: text, context: context)
                try printJSON(insertionPlan)
            case .transcribe(let filePath, let source, let shouldInsert):
                let context = try runtime.contextResolver.resolve(source: source)
                let result = try await runtime.coordinator.transcribeAudioFile(
                    at: URL(fileURLWithPath: filePath),
                    context: context,
                    shouldInsert: shouldInsert
                )
                try runtime.historyStore.recordTranscript(result.transcript, context: context)
                try printJSON(result)
            case .transcribeFile(let filePath, let outputPath, let shouldDiarize, let chunkDurationSeconds):
                let result = try await runtime.audioFileTranscriptionExporter.exportTranscription(
                    of: URL(fileURLWithPath: filePath),
                    options: AudioFileTranscriptionExportOptions(
                        outputFileURL: outputPath.map { URL(fileURLWithPath: $0) },
                        shouldDiarize: shouldDiarize,
                        chunkDurationSeconds: chunkDurationSeconds
                    )
                )
                try printJSON(result)
            case .ask(let prompt, let source):
                let context = try runtime.contextResolver.resolve(source: source)
                let result = try await runtime.coordinator.ask(prompt: prompt, context: context)
                try runtime.historyStore.recordAsk(prompt: prompt, result: result)
                try printJSON(result)
            case .ui:
                return await MainActor.run {
                    runUI()
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        return 0
    }

    private static func bootstrap() throws -> Runtime {
        let loader = ConfigurationLoader()
        let configPath = loader.resolvedConfigPath() ?? "Config/app-config.json"
        let configuration = try loader.load()
        let coordinator = try RuntimeFactory.makeCoordinator(
            configuration: configuration,
            loader: loader
        )

        return Runtime(
            loader: loader,
            configPath: configPath,
            configuration: configuration,
            historyStore: HistoryStore(),
            clipboardStore: ClipboardStore(),
            coordinator: coordinator,
            audioFileTranscriptionExporter: try RuntimeFactory.makeAudioFileTranscriptionExporter(
                configuration: configuration,
                loader: loader
            ),
            doctor: AppDoctor(configuration: configuration),
            contextResolver: ContextResolver()
        )
    }

    private static func runDemo(
        coordinator: AppCoordinator,
        historyStore: HistoryStore
    ) async throws {
        let remoteContext = InputContext(
            kind: .remoteSession,
            sourceApp: "Omnissa Horizon Client",
            payloadSummary: "Clipboard image with a screenshot of a remote Windows error dialog",
            textContent: "Error 0x1234 while opening internal admin portal after SSO redirect."
        )

        let result = try await coordinator.runDemo(context: remoteContext)
        try historyStore.recordTranscript(result.transcript, context: remoteContext)
        let output = DemoOutput(
            transcript: result.transcript,
            insertionPlan: result.insertionPlan,
            askResponse: result.askResponse
        )

        try printJSON(output)
    }

    private static func copyLastTranscript(
        historyStore: HistoryStore,
        clipboardStore: ClipboardStore
    ) throws {
        guard let text = try historyStore.lastTranscript()?.transcript else {
            throw HistoryAccessError.noTranscript
        }

        clipboardStore.copy(text: text)
        print("Copied last transcript to clipboard.")
    }

    private static func copyLastAnswer(
        historyStore: HistoryStore,
        clipboardStore: ClipboardStore
    ) throws {
        guard let text = try historyStore.lastAnswer()?.answer else {
            throw HistoryAccessError.noAnswer
        }

        clipboardStore.copy(text: text)
        print("Copied last answer to clipboard.")
    }

    private static func insertLastTranscript(
        historyStore: HistoryStore,
        clipboardStore: ClipboardStore,
        coordinator: AppCoordinator,
        contextResolver: ContextResolver,
        source: ContextSource
    ) async throws {
        guard let text = try historyStore.lastTranscript()?.transcript else {
            throw HistoryAccessError.noTranscript
        }

        let context = try contextResolver.resolve(source: source)
        let plan = try await coordinator.insert(text: text, context: context)
        clipboardStore.copy(text: text)
        try printJSON(plan)
    }

    private static func setHotkey(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        action: AppHotkeyAction,
        shortcut: String
    ) throws {
        let binding = try HotkeyShortcutParser.parse(shortcut)
        let updated = configuration.updatingHotkey(action, to: binding)
        try loader.save(updated, to: configPath)
        print("Updated \(action.displayName) to \(HotkeyShortcutParser.format(binding)).")
    }

    private static func setSTTBinary(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        path: String
    ) throws {
        let updated = configuration.updatingSTT(binaryPath: path)
        try loader.save(updated, to: configPath)
        print("Updated local STT binary path.")
    }

    private static func setSTTModel(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        path: String
    ) throws {
        let updated = configuration.updatingSTT(modelPath: path)
        try loader.save(updated, to: configPath)
        print("Updated local STT model path.")
    }

    private static func setSTTMode(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        mode: STTMode
    ) throws {
        let updated = configuration.updatingSTT(mode: mode)
        try loader.save(updated, to: configPath)
        print("Updated STT mode to \(mode.rawValue).")
    }

    private static func setSTTAcceleration(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        acceleration: STTAccelerationMode
    ) throws {
        let updated = configuration.updatingSTT(acceleration: acceleration)
        try loader.save(updated, to: configPath)
        print("Updated STT acceleration to \(acceleration.rawValue).")
    }

    private static func setSTTThreads(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        threadCount: Int?
    ) throws {
        let updated = configuration.updatingSTT(threadCount: .some(threadCount))
        try loader.save(updated, to: configPath)
        if let threadCount {
            print("Updated Whisper thread count to \(threadCount).")
        } else {
            print("Reset Whisper thread count to auto.")
        }
    }

    private static func setSTTPromptInstruction(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        prompt: String
    ) throws {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw CommandParseError.invalidSTTPromptInstruction(prompt)
        }

        let updated = configuration.updatingSTT(promptInstruction: .some(normalizedPrompt))
        try loader.save(updated, to: configPath)
        print("Updated STT prompt instruction.")
    }

    private static func clearSTTPromptInstruction(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration
    ) throws {
        let updated = configuration.updatingSTT(promptInstruction: .some(nil))
        try loader.save(updated, to: configPath)
        print("Cleared custom STT prompt instruction. Automatic prompt selection is active again.")
    }

    private static func setMLXPython(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        path: String
    ) throws {
        let updated = configuration.updatingSTT(mlxPythonPath: .some(path))
        try loader.save(updated, to: configPath)
        print("Updated MLX Python path.")
    }

    private static func setMLXModel(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        model: String
    ) throws {
        let updated = configuration.updatingSTT(mlxModel: .some(model))
        try loader.save(updated, to: configPath)
        print("Updated MLX model repo/path.")
    }

    private static func autodetectSTT(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration
    ) throws {
        let result = STTAutodiscoverer(includeSensitiveDirectories: true).discover()
        let updated = AppConfiguration(
            appName: configuration.appName,
            stt: STTConfiguration(
                mode: configuration.stt.mode,
                localeHints: configuration.stt.localeHints,
                binaryPath: result.binaryPath ?? configuration.stt.binaryPath,
                modelPath: result.modelPath ?? configuration.stt.modelPath,
                promptInstruction: configuration.stt.promptInstruction,
                promptTerms: configuration.stt.promptTerms,
                acceleration: configuration.stt.acceleration,
                threadCount: configuration.stt.threadCount,
                mlxPythonPath: result.mlxPythonPath ?? configuration.stt.mlxPythonPath,
                mlxModel: configuration.stt.mlxModel
            ),
            ask: configuration.ask,
            dictionary: configuration.dictionary,
            insertion: configuration.insertion,
            hotkeys: configuration.hotkeys
        )

        try loader.save(updated, to: configPath)
        try printJSON(result)
    }

    private static func setAskModel(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        model: String
    ) throws {
        let updated = configuration.updatingAsk(defaultModel: model)
        try loader.save(updated, to: configPath)
        print("Updated Ask model to \(model).")
    }

    private static func setAskBaseURL(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        baseURL: String
    ) throws {
        let updated = configuration.updatingAsk(baseURL: baseURL)
        try loader.save(updated, to: configPath)
        print("Updated Ask base URL to \(baseURL).")
    }

    private static func setAskAPIKey(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        value: String
    ) throws {
        let askConfiguration = configuration.ask.updating(
            keychainService: configuration.ask.keychainService ?? configuration.appName,
            keychainAccount: configuration.ask.keychainAccount ?? "ask-api-key"
        )
        let updated = configuration.updatingAsk(
            baseURL: askConfiguration.baseURL,
            defaultModel: askConfiguration.defaultModel,
            apiKeyEnvironmentVariable: askConfiguration.apiKeyEnvironmentVariable,
            keychainService: askConfiguration.keychainService,
            keychainAccount: askConfiguration.keychainAccount
        )

        if let service = updated.ask.keychainService,
           let account = updated.ask.keychainAccount {
            try SystemKeychainStore().writePassword(value, service: service, account: account)
        }

        try loader.save(updated, to: configPath)
        print("Saved Ask API key to Keychain.")
    }

    private static func clearAskAPIKey(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration
    ) throws {
        let askConfiguration = configuration.ask.updating(
            keychainService: configuration.ask.keychainService ?? configuration.appName,
            keychainAccount: configuration.ask.keychainAccount ?? "ask-api-key"
        )
        let updated = configuration.updatingAsk(
            baseURL: askConfiguration.baseURL,
            defaultModel: askConfiguration.defaultModel,
            apiKeyEnvironmentVariable: askConfiguration.apiKeyEnvironmentVariable,
            keychainService: askConfiguration.keychainService,
            keychainAccount: askConfiguration.keychainAccount
        )

        if let service = updated.ask.keychainService,
           let account = updated.ask.keychainAccount {
            try SystemKeychainStore().deletePassword(service: service, account: account)
            for legacyService in KeychainServiceCompatibility.legacyServices(for: service) {
                try SystemKeychainStore().deletePassword(service: legacyService, account: account)
            }
        }

        try loader.save(updated, to: configPath)
        print("Cleared Ask API key from Keychain.")
    }

    private static func disableHotkey(
        loader: ConfigurationLoader,
        configPath: String,
        configuration: AppConfiguration,
        action: AppHotkeyAction
    ) throws {
        let updated = configuration.updatingHotkey(action, to: nil)
        try loader.save(updated, to: configPath)
        print("Disabled \(action.displayName).")
    }

    private static func insertLastAnswer(
        historyStore: HistoryStore,
        clipboardStore: ClipboardStore,
        coordinator: AppCoordinator,
        contextResolver: ContextResolver,
        source: ContextSource
    ) async throws {
        guard let text = try historyStore.lastAnswer()?.answer else {
            throw HistoryAccessError.noAnswer
        }

        let context = try contextResolver.resolve(source: source)
        let plan = try await coordinator.insert(text: text, context: context)
        clipboardStore.copy(text: text)
        try printJSON(plan)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}

private struct Runtime {
    let loader: ConfigurationLoader
    let configPath: String
    let configuration: AppConfiguration
    let historyStore: HistoryStore
    let clipboardStore: ClipboardStore
    let coordinator: AppCoordinator
    let audioFileTranscriptionExporter: AudioFileTranscriptionExporter
    let doctor: AppDoctor
    let contextResolver: ContextResolver
}

Task {
    let exitCode = await PlaygroundCLI.run(command: command)
    Foundation.exit(exitCode)
}

dispatchMain()

private enum Command {
    case demo
    case ui
    case config
    case history
    case doctor
    case autodetectSTT
    case requestPermissions
    case setSTTBinary(String)
    case setSTTModel(String)
    case setSTTMode(STTMode)
    case setSTTAcceleration(STTAccelerationMode)
    case setSTTThreads(Int?)
    case setSTTPromptInstruction(String)
    case clearSTTPromptInstruction
    case setMLXPython(String)
    case setMLXModel(String)
    case setAskModel(String)
    case setAskBaseURL(String)
    case setAskAPIKey(String)
    case clearAskAPIKey
    case hotkeys
    case setHotkey(AppHotkeyAction, String)
    case disableHotkey(AppHotkeyAction)
    case lastTranscript
    case lastAnswer
    case copyLastTranscript
    case copyLastAnswer
    case insertLastTranscript(ContextSource)
    case insertLastAnswer(ContextSource)
    case insert(text: String, source: ContextSource)
    case transcribe(filePath: String, source: ContextSource, shouldInsert: Bool)
    case transcribeFile(filePath: String, outputPath: String?, shouldDiarize: Bool, chunkDurationSeconds: Int)
    case context(ContextSource)
    case ask(prompt: String, source: ContextSource)

    static func parse(arguments: [String]) throws -> Command {
        guard let first = arguments.first else {
            return RuntimePaths.launchedFromAppBundle ? .ui : .demo
        }

        switch first {
        case "demo":
            return .demo
        case "ui":
            return .ui
        case "config":
            return .config
        case "history":
            return .history
        case "doctor":
            return .doctor
        case "autodetect-stt":
            return .autodetectSTT
        case "request-permissions":
            return .requestPermissions
        case "set-stt-binary":
            return .setSTTBinary(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-stt-model":
            return .setSTTModel(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-stt-mode":
            return .setSTTMode(try parseSTTMode(Array(arguments.dropFirst())))
        case "set-stt-acceleration":
            return .setSTTAcceleration(try parseSTTAcceleration(Array(arguments.dropFirst())))
        case "set-stt-threads":
            return .setSTTThreads(try parseSTTThreads(Array(arguments.dropFirst())))
        case "set-stt-prompt-instruction":
            return .setSTTPromptInstruction(parseTrailingValue(arguments.dropFirst(), droppingFlags: []))
        case "clear-stt-prompt-instruction":
            return .clearSTTPromptInstruction
        case "set-mlx-python":
            return .setMLXPython(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-mlx-model":
            return .setMLXModel(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-ask-model":
            return .setAskModel(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-ask-base-url":
            return .setAskBaseURL(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "set-ask-api-key":
            return .setAskAPIKey(parseFirstPositionalValue(Array(arguments.dropFirst()), droppingFlags: []))
        case "clear-ask-api-key":
            return .clearAskAPIKey
        case "hotkeys":
            return .hotkeys
        case "set-hotkey":
            let values = Array(arguments.dropFirst())
            return .setHotkey(
                try parseHotkeyAction(values),
                parseFirstPositionalValue(values.dropFirst().map { $0 }, droppingFlags: [])
            )
        case "disable-hotkey":
            return .disableHotkey(try parseHotkeyAction(Array(arguments.dropFirst())))
        case "last-transcript":
            return .lastTranscript
        case "last-answer":
            return .lastAnswer
        case "copy-last-transcript":
            return .copyLastTranscript
        case "copy-last-answer":
            return .copyLastAnswer
        case "insert-last-transcript":
            return .insertLastTranscript(parseSource(arguments.dropFirst()))
        case "insert-last-answer":
            return .insertLastAnswer(parseSource(arguments.dropFirst()))
        case "insert":
            let source = parseSource(arguments.dropFirst())
            let text = parseTrailingValue(arguments.dropFirst(), droppingFlags: ["--source"])
            return .insert(text: text, source: source)
        case "transcribe":
            let values = Array(arguments.dropFirst())
            let source = parseSource(values)
            let shouldInsert = values.contains("--insert")
            let filePath = parseFirstPositionalValue(values, droppingFlags: ["--source", "--insert"])
            return .transcribe(filePath: filePath, source: source, shouldInsert: shouldInsert)
        case "transcribe-file":
            return try parseTranscribeFile(Array(arguments.dropFirst()))
        case "context":
            let source = parseSource(arguments.dropFirst())
            return .context(source)
        case "ask":
            let source = parseSource(arguments.dropFirst())
            let prompt = parsePrompt(arguments.dropFirst())
            return .ask(prompt: prompt, source: source)
        default:
            return .demo
        }
    }

    private static func parseSource<S: Sequence>(_ arguments: S) -> ContextSource where S.Element == String {
        let values = Array(arguments)
        if let index = values.firstIndex(of: "--source"), values.indices.contains(index + 1) {
            return ContextSource(rawValue: values[index + 1]) ?? .auto
        }
        return .auto
    }

    private static func parsePrompt<S: Sequence>(_ arguments: S) -> String where S.Element == String {
        parseTrailingValue(arguments, droppingFlags: ["--source"])
    }

    private static func parseTranscribeFile(_ arguments: [String]) throws -> Command {
        let filePath = parseTranscribeFileInputPath(arguments)
        let outputPath = parseFlagValue("--output", in: arguments)
        let shouldDiarize = arguments.contains("--diarize")
        let chunkDurationSeconds = try parsePositiveIntegerFlag("--chunk-seconds", in: arguments) ?? 900
        return .transcribeFile(
            filePath: filePath,
            outputPath: outputPath,
            shouldDiarize: shouldDiarize,
            chunkDurationSeconds: chunkDurationSeconds
        )
    }

    private static func parseTranscribeFileInputPath(_ arguments: [String]) -> String {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--diarize" {
                index += 1
                continue
            }
            if value == "--output" || value == "--chunk-seconds" {
                index += 2
                continue
            }
            return value
        }
        return ""
    }

    private static func parseFlagValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parsePositiveIntegerFlag(
        _ flag: String,
        in arguments: [String]
    ) throws -> Int? {
        guard let value = parseFlagValue(flag, in: arguments) else {
            return nil
        }

        guard let integerValue = Int(value), integerValue > 0 else {
            throw CommandParseError.invalidPositiveIntegerFlag(flag: flag, value: value)
        }

        return integerValue
    }

    private static func parseTrailingValue<S: Sequence>(
        _ arguments: S,
        droppingFlags: Set<String>
    ) -> String where S.Element == String {
        let values = Array(arguments)
        var filtered: [String] = []
        var index = 0

        while index < values.count {
            if values[index] == "--source" {
                index += 2
                continue
            }
            if values[index] == "--insert" {
                index += 1
                continue
            }
            filtered.append(values[index])
            index += 1
        }

        return filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseFirstPositionalValue(
        _ arguments: [String],
        droppingFlags: Set<String>
    ) -> String {
        var index = 0
        while index < arguments.count {
            if droppingFlags.contains(arguments[index]) {
                index += arguments[index] == "--insert" ? 1 : 2
                continue
            }
            return arguments[index]
        }
        return ""
    }

    private static func parseHotkeyAction(_ arguments: [String]) throws -> AppHotkeyAction {
        guard let first = arguments.first else {
            throw CommandParseError.invalidHotkeyAction("")
        }
        guard let action = AppHotkeyAction(rawValue: first) else {
            throw CommandParseError.invalidHotkeyAction(first)
        }
        return action
    }

    private static func parseSTTMode(_ arguments: [String]) throws -> STTMode {
        guard let first = arguments.first, let mode = STTMode(rawValue: first) else {
            throw CommandParseError.invalidSTTMode(arguments.first ?? "")
        }
        return mode
    }

    private static func parseSTTAcceleration(_ arguments: [String]) throws -> STTAccelerationMode {
        guard let first = arguments.first, let acceleration = STTAccelerationMode(rawValue: first) else {
            throw CommandParseError.invalidSTTAcceleration(arguments.first ?? "")
        }
        return acceleration
    }

    private static func parseSTTThreads(_ arguments: [String]) throws -> Int? {
        guard let first = arguments.first else {
            throw CommandParseError.invalidSTTThreadCount("")
        }

        if first == "auto" {
            return nil
        }

        guard let threadCount = Int(first), threadCount > 0 else {
            throw CommandParseError.invalidSTTThreadCount(first)
        }

        return threadCount
    }
}

private enum CommandParseError: LocalizedError {
    case invalidHotkeyAction(String)
    case invalidSTTMode(String)
    case invalidSTTAcceleration(String)
    case invalidSTTThreadCount(String)
    case invalidSTTPromptInstruction(String)
    case invalidPositiveIntegerFlag(flag: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidHotkeyAction(let value):
            let valid = AppHotkeyAction.allCases.map(\.rawValue).joined(separator: ", ")
            return "Invalid hotkey action '\(value)'. Valid actions: \(valid)"
        case .invalidSTTMode(let value):
            let valid = [STTMode.automaticLocal, .appleSpeech, .localWhisper, .cloudBackup]
                .map(\.rawValue)
                .joined(separator: ", ")
            return "Invalid STT mode '\(value)'. Valid modes: \(valid)"
        case .invalidSTTAcceleration(let value):
            let valid = [STTAccelerationMode.cpu, .auto, .metal, .mlx]
                .map(\.rawValue)
                .joined(separator: ", ")
            return "Invalid STT acceleration '\(value)'. Valid accelerations: \(valid)"
        case .invalidSTTThreadCount(let value):
            return "Invalid Whisper thread count '\(value)'. Use a positive integer or 'auto'."
        case .invalidSTTPromptInstruction:
            return "Invalid STT prompt instruction. Use a non-empty string or 'clear-stt-prompt-instruction' to reset it."
        case .invalidPositiveIntegerFlag(let flag, let value):
            return "Invalid value '\(value)' for \(flag). Use a positive integer."
        }
    }
}

private enum HistoryAccessError: LocalizedError {
    case noTranscript
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "No transcript is available in history."
        case .noAnswer:
            return "No Ask Anything answer is available in history."
        }
    }
}

private struct DemoOutput: Codable {
    let transcript: Transcript
    let insertionPlan: InsertionPlan
    let askResponse: AskResponse
}
