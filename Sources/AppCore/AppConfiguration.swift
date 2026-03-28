import Foundation

public struct AppConfiguration: Codable, Sendable {
    public let appName: String
    public let stt: STTConfiguration
    public let ask: AskConfiguration
    public let dictionary: DictionaryConfiguration
    public let insertion: InsertionConfiguration
    public let hotkeys: HotkeyConfiguration

    public init(
        appName: String,
        stt: STTConfiguration,
        ask: AskConfiguration,
        dictionary: DictionaryConfiguration,
        insertion: InsertionConfiguration,
        hotkeys: HotkeyConfiguration
    ) {
        self.appName = appName
        self.stt = stt
        self.ask = ask
        self.dictionary = dictionary
        self.insertion = insertion
        self.hotkeys = hotkeys
    }

    public static func sample() -> AppConfiguration {
        AppConfiguration(
            appName: "OmniVoice",
            stt: STTConfiguration(
                mode: .localWhisper,
                localeHints: ["zh-CN", "en-US"],
                binaryPath: "STT/whisper-cli",
                modelPath: "STT/ggml-medium.bin",
                promptInstruction: nil,
                promptTerms: ["OpenCLAW", "Horizon Client", "Typeless"],
                acceleration: .cpu,
                mlxPythonPath: ".venv-mlx/bin/python",
                mlxModel: "mlx-community/whisper-large-v3-turbo"
            ),
            ask: AskConfiguration(
                provider: .customOpenAICompatible,
                baseURL: "https://openrouter.ai/api/v1",
                defaultModel: "openrouter/auto",
                apiKeyEnvironmentVariable: "OPENROUTER_API_KEY",
                keychainService: "OmniVoice",
                keychainAccount: "ask-api-key",
                supportsImageContext: true,
                systemPrompt: "You are a concise desktop assistant. Prefer actionable answers. Preserve technical terms and mixed Chinese-English terminology."
            ),
            dictionary: DictionaryConfiguration(
                entries: [
                    DictionaryEntry(spokenForms: ["open claw", "openclaw"], target: "OpenCLAW"),
                    DictionaryEntry(spokenForms: ["horizon client"], target: "Horizon Client"),
                ],
                filePath: "Config/dictionary.json"
            ),
            insertion: InsertionConfiguration(
                remoteAppHints: ["Omnissa Horizon Client", "VMware Horizon Client", "Citrix Workspace", "Microsoft Remote Desktop"],
                localDefault: InsertionPlan(
                    mode: .directAccessibility,
                    delayMilliseconds: 0,
                    attemptCount: 1,
                    retryIntervalMilliseconds: 0,
                    shouldRestoreClipboard: false
                ),
                remoteDefault: InsertionPlan(
                    mode: .remoteSafePaste,
                    delayMilliseconds: 900,
                    attemptCount: 1,
                    retryIntervalMilliseconds: 0,
                    shouldRestoreClipboard: true
                )
            ),
            hotkeys: HotkeyConfiguration(
                toggleDictation: HotkeyBinding(
                    keyCode: HotkeyBinding.modifierOnlyKeyCode,
                    modifiers: [.rightOption]
                ),
                askSelectedText: HotkeyBinding(keyCode: 7, modifiers: [.command, .option]),
                askClipboard: HotkeyBinding(
                    keyCode: HotkeyBinding.modifierOnlyKeyCode,
                    modifiers: [.rightCommand, .rightOption]
                ),
                askScreenshot: HotkeyBinding(
                    keyCode: 49,
                    modifiers: [.rightOption]
                ),
                runDoctor: HotkeyBinding(keyCode: 2, modifiers: [.command, .option])
            )
        )
    }
}

public enum STTMode: String, Codable, Sendable {
    case automaticLocal
    case appleSpeech
    case localWhisper
    case cloudBackup

    public var displayName: String {
        switch self {
        case .automaticLocal:
            return "Automatic Local"
        case .appleSpeech:
            return "Apple Speech"
        case .localWhisper:
            return "whisper.cpp"
        case .cloudBackup:
            return "Cloud Backup"
        }
    }
}

public enum STTAccelerationMode: String, Codable, Sendable {
    case cpu
    case auto
    case metal
    case mlx

    public var displayName: String {
        switch self {
        case .cpu:
            return "CPU"
        case .auto:
            return "Auto"
        case .metal:
            return "Metal"
        case .mlx:
            return "MLX"
        }
    }
}

public struct STTConfiguration: Codable, Sendable {
    public let mode: STTMode
    public let localeHints: [String]
    public let binaryPath: String?
    public let modelPath: String?
    public let promptInstruction: String?
    public let promptTerms: [String]
    public let acceleration: STTAccelerationMode
    public let threadCount: Int?
    public let mlxPythonPath: String?
    public let mlxModel: String?

    public init(
        mode: STTMode,
        localeHints: [String],
        binaryPath: String? = nil,
        modelPath: String? = nil,
        promptInstruction: String? = nil,
        promptTerms: [String] = [],
        acceleration: STTAccelerationMode = .cpu,
        threadCount: Int? = nil,
        mlxPythonPath: String? = nil,
        mlxModel: String? = nil
    ) {
        self.mode = mode
        self.localeHints = localeHints
        self.binaryPath = binaryPath
        self.modelPath = modelPath
        self.promptInstruction = promptInstruction
        self.promptTerms = promptTerms
        self.acceleration = acceleration
        self.threadCount = threadCount
        self.mlxPythonPath = mlxPythonPath
        self.mlxModel = mlxModel
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case localeHints
        case binaryPath
        case modelPath
        case promptInstruction
        case promptTerms
        case acceleration
        case threadCount
        case mlxPythonPath
        case mlxModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(STTMode.self, forKey: .mode)
        localeHints = try container.decodeIfPresent([String].self, forKey: .localeHints) ?? []
        binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath)
        modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
        promptInstruction = try container.decodeIfPresent(String.self, forKey: .promptInstruction)
        promptTerms = try container.decodeIfPresent([String].self, forKey: .promptTerms) ?? []
        acceleration = try container.decodeIfPresent(STTAccelerationMode.self, forKey: .acceleration) ?? .cpu
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount)
        mlxPythonPath = try container.decodeIfPresent(String.self, forKey: .mlxPythonPath)
        mlxModel = try container.decodeIfPresent(String.self, forKey: .mlxModel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(localeHints, forKey: .localeHints)
        try container.encodeIfPresent(binaryPath, forKey: .binaryPath)
        try container.encodeIfPresent(modelPath, forKey: .modelPath)
        try container.encodeIfPresent(promptInstruction, forKey: .promptInstruction)
        try container.encode(promptTerms, forKey: .promptTerms)
        try container.encode(acceleration, forKey: .acceleration)
        try container.encodeIfPresent(threadCount, forKey: .threadCount)
        try container.encodeIfPresent(mlxPythonPath, forKey: .mlxPythonPath)
        try container.encodeIfPresent(mlxModel, forKey: .mlxModel)
    }
}

public enum AskProviderKind: String, Codable, Sendable {
    case openAI
    case openRouter
    case customOpenAICompatible
}

public struct AskConfiguration: Codable, Sendable {
    public let provider: AskProviderKind
    public let baseURL: String
    public let defaultModel: String
    public let apiKeyEnvironmentVariable: String
    public let keychainService: String?
    public let keychainAccount: String?
    public let supportsImageContext: Bool
    public let systemPrompt: String

    public init(
        provider: AskProviderKind,
        baseURL: String,
        defaultModel: String,
        apiKeyEnvironmentVariable: String,
        keychainService: String? = nil,
        keychainAccount: String? = nil,
        supportsImageContext: Bool,
        systemPrompt: String
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.supportsImageContext = supportsImageContext
        self.systemPrompt = systemPrompt
    }
}

public struct DictionaryConfiguration: Codable, Sendable {
    public let entries: [DictionaryEntry]
    public let filePath: String?

    public init(entries: [DictionaryEntry], filePath: String? = nil) {
        self.entries = entries
        self.filePath = filePath
    }
}

public struct InsertionConfiguration: Codable, Sendable {
    public let remoteAppHints: [String]
    public let localDefault: InsertionPlan
    public let remoteDefault: InsertionPlan

    public init(remoteAppHints: [String], localDefault: InsertionPlan, remoteDefault: InsertionPlan) {
        self.remoteAppHints = remoteAppHints
        self.localDefault = localDefault
        self.remoteDefault = remoteDefault
    }
}

public struct HotkeyConfiguration: Codable, Sendable {
    public let toggleDictation: HotkeyBinding?
    public let askSelectedText: HotkeyBinding?
    public let askClipboard: HotkeyBinding?
    public let askScreenshot: HotkeyBinding?
    public let runDoctor: HotkeyBinding?

    public init(
        toggleDictation: HotkeyBinding?,
        askSelectedText: HotkeyBinding?,
        askClipboard: HotkeyBinding?,
        askScreenshot: HotkeyBinding?,
        runDoctor: HotkeyBinding?
    ) {
        self.toggleDictation = toggleDictation
        self.askSelectedText = askSelectedText
        self.askClipboard = askClipboard
        self.askScreenshot = askScreenshot
        self.runDoctor = runDoctor
    }
}

public struct HotkeyBinding: Codable, Sendable, Hashable {
    public static let modifierOnlyKeyCode = -1

    public let keyCode: Int
    public let modifiers: [HotkeyModifier]

    public init(keyCode: Int, modifiers: [HotkeyModifier]) {
        self.keyCode = keyCode
        self.modifiers = Array(Set(modifiers)).sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    public var isModifierOnly: Bool {
        keyCode == Self.modifierOnlyKeyCode
    }
}

public enum HotkeyModifier: String, Codable, Sendable {
    case command
    case leftCommand
    case rightCommand
    case option
    case leftOption
    case rightOption
    case control
    case leftControl
    case rightControl
    case shift
    case leftShift
    case rightShift
}

public enum HotkeyModifierFamily: String, Codable, Sendable {
    case command
    case option
    case control
    case shift
}

public enum HotkeyModifierSide: String, Codable, Sendable {
    case left
    case right
}

public extension HotkeyModifier {
    var family: HotkeyModifierFamily {
        switch self {
        case .command, .leftCommand, .rightCommand:
            return .command
        case .option, .leftOption, .rightOption:
            return .option
        case .control, .leftControl, .rightControl:
            return .control
        case .shift, .leftShift, .rightShift:
            return .shift
        }
    }

    var side: HotkeyModifierSide? {
        switch self {
        case .leftCommand, .leftOption, .leftControl, .leftShift:
            return .left
        case .rightCommand, .rightOption, .rightControl, .rightShift:
            return .right
        case .command, .option, .control, .shift:
            return nil
        }
    }

    var isGeneric: Bool {
        side == nil
    }

    var sortOrder: Int {
        switch self {
        case .leftCommand:
            return 0
        case .rightCommand:
            return 1
        case .command:
            return 2
        case .leftOption:
            return 3
        case .rightOption:
            return 4
        case .option:
            return 5
        case .leftControl:
            return 6
        case .rightControl:
            return 7
        case .control:
            return 8
        case .leftShift:
            return 9
        case .rightShift:
            return 10
        case .shift:
            return 11
        }
    }

    static func specific(_ family: HotkeyModifierFamily, side: HotkeyModifierSide) -> HotkeyModifier {
        switch (family, side) {
        case (.command, .left):
            return .leftCommand
        case (.command, .right):
            return .rightCommand
        case (.option, .left):
            return .leftOption
        case (.option, .right):
            return .rightOption
        case (.control, .left):
            return .leftControl
        case (.control, .right):
            return .rightControl
        case (.shift, .left):
            return .leftShift
        case (.shift, .right):
            return .rightShift
        }
    }

    static func generic(_ family: HotkeyModifierFamily) -> HotkeyModifier {
        switch family {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
        }
    }
}
