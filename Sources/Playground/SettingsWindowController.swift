import AppCore
import AppKit
import Foundation

private enum SettingsValidationError: LocalizedError {
    case missingRequiredField(String)
    case invalidPositiveInteger(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let fieldName):
            return "\(fieldName) cannot be empty."
        case .invalidPositiveInteger(let fieldName):
            return "\(fieldName) must be a positive integer."
        }
    }
}

@MainActor
struct SettingsSaveRequest {
    let configuration: AppConfiguration
    let apiKeyChange: AskAPIKeyChange
}

enum AskAPIKeyChange {
    case unchanged
    case set(String)
    case clear
}

private enum MLXWhisperModelPreset: String, CaseIterable {
    case largeV3Turbo
    case medium
    case largeV3
    case custom

    var displayName: String {
        switch self {
        case .largeV3Turbo:
            return "Large V3 Turbo"
        case .medium:
            return "Medium"
        case .largeV3:
            return "Large V3"
        case .custom:
            return "Custom"
        }
    }

    var modelIdentifier: String? {
        switch self {
        case .largeV3Turbo:
            return "mlx-community/whisper-large-v3-turbo"
        case .medium:
            return "mlx-community/whisper-medium-mlx"
        case .largeV3:
            return "mlx-community/whisper-large-v3-mlx"
        case .custom:
            return nil
        }
    }

    static func matching(modelIdentifier: String?) -> Self {
        guard let trimmed = modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .largeV3Turbo
        }

        return allCases.first(where: { $0.modelIdentifier == trimmed }) ?? .custom
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let saveHandler: (SettingsSaveRequest) -> Void

    private var configuration: AppConfiguration

    private let sttModePopUp = NSPopUpButton()
    private let sttAccelerationPopUp = NSPopUpButton()
    private let sttBinaryField = NSTextField()
    private let sttModelField = NSTextField()
    private let sttThreadCountField = NSTextField()
    private let mlxPythonField = NSTextField()
    private let mlxModelPresetPopUp = NSPopUpButton()
    private let mlxModelField = NSTextField()
    private let promptInstructionField = NSTextField()
    private let askBaseURLField = NSTextField()
    private let askModelField = NSTextField()
    private let askAPIKeyField = NSSecureTextField()
    private let clearAPIKeyButton = NSButton(checkboxWithTitle: "Clear saved API key from Keychain", target: nil, action: nil)
    private let promptTermsField = NSTextField()
    private var hotkeyControls: [AppHotkeyAction: HotkeyRecorderControl] = [:]

    init(
        configuration: AppConfiguration,
        saveHandler: @escaping (SettingsSaveRequest) -> Void
    ) {
        self.configuration = configuration
        self.saveHandler = saveHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
        buildInterface()
        load(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(configuration: AppConfiguration) {
        self.configuration = configuration
        configureSTTModePopUp()
        configureSTTAccelerationPopUp()
        sttBinaryField.stringValue = configuration.stt.binaryPath ?? ""
        sttModelField.stringValue = configuration.stt.modelPath ?? ""
        sttThreadCountField.stringValue = configuration.stt.threadCount.map { String($0) } ?? ""
        mlxPythonField.stringValue = configuration.stt.mlxPythonPath ?? ""
        configureMLXModelPresetPopUp()
        mlxModelField.stringValue = configuration.stt.mlxModel ?? ""
        promptInstructionField.stringValue = configuration.stt.promptInstruction ?? ""
        askBaseURLField.stringValue = configuration.ask.baseURL
        askModelField.stringValue = configuration.ask.defaultModel
        askAPIKeyField.stringValue = ""
        clearAPIKeyButton.state = .off
        promptTermsField.stringValue = configuration.stt.promptTerms.joined(separator: ", ")
        selectSTTMode(configuration.stt.mode)
        selectSTTAcceleration(configuration.stt.acceleration)
        selectMLXModelPreset(matching: configuration.stt.mlxModel)

        for action in AppHotkeyAction.allCases {
            hotkeyControls[action]?.binding = configuration.hotkeys.binding(for: action)
        }
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -40),
        ])

        stack.addArrangedSubview(sectionLabel("Speech"))
        stack.addArrangedSubview(viewRow(label: "STT mode", view: sttModePopUp))
        stack.addArrangedSubview(viewRow(label: "Acceleration", view: sttAccelerationPopUp))
        stack.addArrangedSubview(formRow(label: "whisper-cli path", field: sttBinaryField))
        stack.addArrangedSubview(formRow(label: "whisper model path", field: sttModelField))
        stack.addArrangedSubview(formRow(label: "Whisper threads", field: sttThreadCountField))
        stack.addArrangedSubview(formRow(label: "MLX Python path", field: mlxPythonField))
        stack.addArrangedSubview(viewRow(label: "MLX model preset", view: mlxModelPresetPopUp))
        stack.addArrangedSubview(formRow(label: "MLX model repo/path", field: mlxModelField))
        stack.addArrangedSubview(formRow(label: "STT prompt instruction", field: promptInstructionField))
        stack.addArrangedSubview(formRow(label: "Prompt terms", field: promptTermsField))
        sttThreadCountField.placeholderString = "auto"
        mlxPythonField.placeholderString = ".venv-mlx/bin/python"
        mlxModelField.placeholderString = "mlx-community/whisper-large-v3-turbo"
        promptInstructionField.placeholderString = ChineseScriptPreference
            .fromPreferredLanguages()
            .whisperPromptInstruction
        mlxModelPresetPopUp.target = self
        mlxModelPresetPopUp.action = #selector(mlxModelPresetChanged)
        stack.addArrangedSubview(helperLabel("Automatic Local prefers local STT when available and falls back to Apple Speech when it is not configured. CPU/Auto/Metal use whisper.cpp. MLX uses a separate Python runtime plus an MLX Whisper model repo or local directory. The preset picker fills in common MLX Whisper models, while the repo/path field still accepts any custom Hugging Face repo or local MLX model directory. Leave STT prompt instruction blank to keep the automatic mixed-language prompt. Prompt terms stay as lightweight vocabulary hints. Leave Whisper threads blank to let the app choose a conservative default instead of pegging every core."))

        stack.addArrangedSubview(sectionLabel("Ask Anything"))
        stack.addArrangedSubview(formRow(label: "Base URL", field: askBaseURLField))
        stack.addArrangedSubview(formRow(label: "Model", field: askModelField))
        stack.addArrangedSubview(formRow(label: "API key", field: askAPIKeyField))
        stack.addArrangedSubview(clearAPIKeyButton)
        stack.addArrangedSubview(helperLabel("Save a new API key to macOS Keychain or leave this blank to keep the current one. Environment variables still take precedence."))

        stack.addArrangedSubview(sectionLabel("Hotkeys"))
        for action in AppHotkeyAction.allCases {
            let control = HotkeyRecorderControl()
            hotkeyControls[action] = control
            stack.addArrangedSubview(viewRow(label: action.displayName, view: control))
        }
        stack.addArrangedSubview(helperLabel("Click Record Shortcut to open the recorder window, then press the shortcut you want. For modifier-only shortcuts, press the modifiers and release one of them to confirm. Left and right Command/Option/Control/Shift are captured separately. Press Delete to clear or Escape to cancel."))

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        let buttonRow = NSStackView(views: [saveButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        stack.addArrangedSubview(buttonRow)

        window.contentView = scrollView
    }

    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func helperLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func formRow(label: String, field: NSTextField) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        return viewRow(label: label, view: field)
    }

    private func viewRow(label: String, view: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.alignment = .right

        let grid = NSGridView(views: [[title, view]])
        grid.rowSpacing = 8
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.column(at: 0).width = 170
        return grid
    }

    @objc
    private func saveSettings() {
        do {
            let request = try saveRequest()
            saveHandler(request)
            close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Settings Error"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc
    private func cancelSettings() {
        close()
    }

    private func saveRequest() throws -> SettingsSaveRequest {
        let baseURL = try normalizedRequiredValue(askBaseURLField, fieldName: "Ask base URL")
        let model = try normalizedRequiredValue(askModelField, fieldName: "Ask model")
        let promptTerms = promptTermsField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var hotkeys = configuration.hotkeys
        for action in AppHotkeyAction.allCases {
            let binding = hotkeyControls[action]?.binding
            hotkeys = hotkeys.updating(action, to: binding)
        }

        let selectedMode = STTMode(rawValue: sttModePopUp.selectedItem?.representedObject as? String ?? "") ?? configuration.stt.mode
        let selectedAcceleration = STTAccelerationMode(
            rawValue: sttAccelerationPopUp.selectedItem?.representedObject as? String ?? ""
        ) ?? configuration.stt.acceleration
        let threadCount = try normalizedOptionalPositiveInteger(sttThreadCountField, fieldName: "Whisper threads")
        let stt = STTConfiguration(
            mode: selectedMode,
            localeHints: configuration.stt.localeHints,
            binaryPath: normalizedOptionalValue(sttBinaryField),
            modelPath: normalizedOptionalValue(sttModelField),
            promptInstruction: normalizedOptionalValue(promptInstructionField),
            promptTerms: promptTerms,
            acceleration: selectedAcceleration,
            threadCount: threadCount,
            mlxPythonPath: normalizedOptionalValue(mlxPythonField),
            mlxModel: normalizedOptionalValue(mlxModelField)
        )

        let ask = AskConfiguration(
            provider: configuration.ask.provider,
            baseURL: baseURL,
            defaultModel: model,
            apiKeyEnvironmentVariable: configuration.ask.apiKeyEnvironmentVariable,
            keychainService: configuration.ask.keychainService ?? configuration.appName,
            keychainAccount: configuration.ask.keychainAccount ?? "ask-api-key",
            supportsImageContext: configuration.ask.supportsImageContext,
            systemPrompt: configuration.ask.systemPrompt
        )

        let updatedConfiguration = AppConfiguration(
            appName: configuration.appName,
            stt: stt,
            ask: ask,
            dictionary: configuration.dictionary,
            insertion: configuration.insertion,
            hotkeys: hotkeys
        )

        let apiKeyValue = askAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyChange: AskAPIKeyChange
        if !apiKeyValue.isEmpty {
            apiKeyChange = .set(apiKeyValue)
        } else if clearAPIKeyButton.state == .on {
            apiKeyChange = .clear
        } else {
            apiKeyChange = .unchanged
        }

        return SettingsSaveRequest(
            configuration: updatedConfiguration,
            apiKeyChange: apiKeyChange
        )
    }

    private func normalizedRequiredValue(_ field: NSTextField, fieldName: String) throws -> String {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SettingsValidationError.missingRequiredField(fieldName)
        }
        return value
    }

    private func normalizedOptionalValue(_ field: NSTextField) -> String? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func normalizedOptionalPositiveInteger(_ field: NSTextField, fieldName: String) throws -> Int? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        guard let parsed = Int(value), parsed > 0 else {
            throw SettingsValidationError.invalidPositiveInteger(fieldName)
        }

        return parsed
    }

    private func configureSTTModePopUp() {
        sttModePopUp.removeAllItems()
        let modes: [STTMode] = [.automaticLocal, .appleSpeech, .localWhisper]
        for mode in modes {
            sttModePopUp.addItem(withTitle: mode.displayName)
            sttModePopUp.lastItem?.representedObject = mode.rawValue
        }
    }

    private func configureSTTAccelerationPopUp() {
        sttAccelerationPopUp.removeAllItems()
        let accelerations: [STTAccelerationMode] = [.cpu, .auto, .metal, .mlx]
        for acceleration in accelerations {
            sttAccelerationPopUp.addItem(withTitle: acceleration.displayName)
            sttAccelerationPopUp.lastItem?.representedObject = acceleration.rawValue
        }
    }

    private func configureMLXModelPresetPopUp() {
        mlxModelPresetPopUp.removeAllItems()
        for preset in MLXWhisperModelPreset.allCases {
            mlxModelPresetPopUp.addItem(withTitle: preset.displayName)
            mlxModelPresetPopUp.lastItem?.representedObject = preset.rawValue
        }
    }

    private func selectSTTMode(_ mode: STTMode) {
        guard let index = sttModePopUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == mode.rawValue }) else {
            return
        }
        sttModePopUp.selectItem(at: index)
    }

    private func selectSTTAcceleration(_ acceleration: STTAccelerationMode) {
        guard let index = sttAccelerationPopUp.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == acceleration.rawValue
        }) else {
            return
        }
        sttAccelerationPopUp.selectItem(at: index)
    }

    private func selectMLXModelPreset(matching modelIdentifier: String?) {
        let preset = MLXWhisperModelPreset.matching(modelIdentifier: modelIdentifier)
        guard let index = mlxModelPresetPopUp.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == preset.rawValue
        }) else {
            return
        }
        mlxModelPresetPopUp.selectItem(at: index)
    }

    @objc
    private func mlxModelPresetChanged() {
        guard let rawValue = mlxModelPresetPopUp.selectedItem?.representedObject as? String,
              let preset = MLXWhisperModelPreset(rawValue: rawValue),
              let modelIdentifier = preset.modelIdentifier else {
            return
        }

        mlxModelField.stringValue = modelIdentifier
    }
}
