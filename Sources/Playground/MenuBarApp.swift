import AppCore
import AppKit
import Foundation

@MainActor
final class MenuBarApplicationController: NSObject, NSApplicationDelegate {
    private var configuration: AppConfiguration
    private var coordinator: AppCoordinator
    private let contextResolver: ContextResolver
    private let historyStore: HistoryStore
    private let configPath: String
    private let configurationLoader: ConfigurationLoader
    private let keychainStore: KeychainStoring
    private var hotkeys: HotkeyConfiguration
    private let audioRecorder = AudioRecorder()
    private let hotKeyManager = HotKeyManager()
    private let dictationOverlayController = DictationOverlayController()
    private let dictationSoundPlayer = DictationSoundPlayer()
    private var statusItem: NSStatusItem?
    private var startRecordingItem: NSMenuItem?
    private var stopRecordingItem: NSMenuItem?
    private var settingsWindowController: SettingsWindowController?
    private var dictionaryWindowController: DictionaryEditorWindowController?
    private var setupWindowController: SetupWindowController?
    private var historyWindowController: HistoryWindowController?
    private var audioFileTranscriptionWindowController: AudioFileTranscriptionWindowController?
    private var activeTranscriptionTask: Task<Void, Never>?
    private var audioFileTranscriptionExporter: AudioFileTranscriptionExporter

    init(
        configuration: AppConfiguration,
        coordinator: AppCoordinator,
        audioFileTranscriptionExporter: AudioFileTranscriptionExporter,
        contextResolver: ContextResolver,
        historyStore: HistoryStore,
        hotkeys: HotkeyConfiguration,
        configPath: String,
        configurationLoader: ConfigurationLoader = ConfigurationLoader(),
        keychainStore: KeychainStoring = SystemKeychainStore()
    ) {
        self.configuration = configuration
        self.coordinator = coordinator
        self.audioFileTranscriptionExporter = audioFileTranscriptionExporter
        self.contextResolver = contextResolver
        self.historyStore = historyStore
        self.hotkeys = hotkeys
        self.configPath = configPath
        self.configurationLoader = configurationLoader
        self.keychainStore = keychainStore
        super.init()
        audioRecorder.levelObserver = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.dictationOverlayController.updateRecordingLevel(level)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureStatusItem()
        registerHotKeys()
        presentSetupOnFirstLaunchIfNeeded()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.title = ""
            button.image = statusIcon(named: "waveform.circle", fallback: "waveform", accessibilityDescription: configuration.appName)
            button.imagePosition = .imageOnly
            button.toolTip = configuration.appName
        }

        let menu = NSMenu()
        let startRecordingItem = NSMenuItem(title: "Start Dictation", action: #selector(startDictation), keyEquivalent: "r")
        let stopRecordingItem = NSMenuItem(title: "Stop Dictation", action: #selector(stopDictation), keyEquivalent: "t")
        self.startRecordingItem = startRecordingItem
        self.stopRecordingItem = stopRecordingItem

        menu.addItem(startRecordingItem)
        menu.addItem(stopRecordingItem)
        menu.addItem(NSMenuItem(title: "Transcribe Audio File…", action: #selector(openAudioFileTranscription), keyEquivalent: "f"))
        menu.addItem(.separator())
        menu.addItem(submenuItem(
            title: "Ask",
            items: [
                NSMenuItem(title: "Ask Selected Text", action: #selector(askSelectedText), keyEquivalent: "x"),
                NSMenuItem(title: "Ask Clipboard", action: #selector(askClipboard), keyEquivalent: "c"),
                NSMenuItem(title: "Ask Screenshot", action: #selector(askScreenshot), keyEquivalent: "s"),
            ]
        ))
        menu.addItem(submenuItem(
            title: "Library",
            items: [
                NSMenuItem(title: "Open History", action: #selector(openHistory), keyEquivalent: "y"),
                NSMenuItem(title: "Insert Last Transcript", action: #selector(insertLastTranscript), keyEquivalent: "1"),
                NSMenuItem(title: "Insert Last Answer", action: #selector(insertLastAnswer), keyEquivalent: "2"),
                NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "l"),
                NSMenuItem(title: "Copy Last Answer", action: #selector(copyLastAnswer), keyEquivalent: "a"),
            ]
        ))
        menu.addItem(submenuItem(
            title: "Tools",
            items: [
                NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","),
                NSMenuItem(title: "Edit Dictionary", action: #selector(openDictionaryEditor), keyEquivalent: ""),
                NSMenuItem(title: "Open Setup", action: #selector(openSetup), keyEquivalent: "u"),
                NSMenuItem(title: "Show Hotkeys", action: #selector(showHotkeys), keyEquivalent: "h"),
                NSMenuItem.separator(),
                NSMenuItem(title: "Inspect Context", action: #selector(inspectAutoContext), keyEquivalent: "i"),
                NSMenuItem(title: "Auto-Detect STT", action: #selector(autoDetectSTT), keyEquivalent: ""),
                NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ""),
                NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: "p"),
                NSMenuItem(title: "Run Doctor", action: #selector(runDoctor), keyEquivalent: "d"),
            ]
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        applyTarget(to: menu)
        statusItem.menu = menu
        updateRecordingMenuState()
    }

    private func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for item in items {
            submenu.addItem(item)
        }
        menuItem.submenu = submenu
        return menuItem
    }

    private func applyTarget(to menu: NSMenu) {
        for item in menu.items {
            if item.action != nil {
                item.target = self
            }
            if let submenu = item.submenu {
                applyTarget(to: submenu)
            }
        }
    }

    private func statusIcon(
        named name: String,
        fallback: String,
        accessibilityDescription: String
    ) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: accessibilityDescription)
    }

    private func registerHotKeys() {
        do {
            if let binding = hotkeys.toggleDictation {
                try hotKeyManager.register(binding) { [weak self] in
                    self?.toggleDictation()
                }
            }

            if let binding = hotkeys.askSelectedText {
                try hotKeyManager.register(binding) { [weak self] in
                    self?.askSelectedText()
                }
            }

            if let binding = hotkeys.askClipboard {
                try hotKeyManager.register(binding) { [weak self] in
                    self?.askClipboard()
                }
            }

            if let binding = hotkeys.askScreenshot {
                try hotKeyManager.register(binding) { [weak self] in
                    self?.askScreenshot()
                }
            }

            if let binding = hotkeys.runDoctor {
                try hotKeyManager.register(binding) { [weak self] in
                    self?.runDoctor()
                }
            }
        } catch {
            presentInfoAlert(title: "Hotkey Registration Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func askClipboard() {
        ask(using: .clipboard, defaultPrompt: "解释一下我刚复制的内容")
    }

    @objc
    private func askSelectedText() {
        ask(using: .selected, defaultPrompt: "解释一下我当前选中的内容")
    }

    @objc
    private func copyLastTranscript() {
        do {
            guard let transcript = try historyStore.lastTranscript()?.transcript else {
                presentInfoAlert(title: "No Transcript", message: "No transcript has been recorded yet.")
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(transcript, forType: .string)
        } catch {
            presentInfoAlert(title: "Copy Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func insertLastTranscript() {
        do {
            guard let transcript = try historyStore.lastTranscript()?.transcript else {
                presentInfoAlert(title: "No Transcript", message: "No transcript has been recorded yet.")
                return
            }

            Task {
                do {
                    let context = contextResolver.resolveInsertionTargetContext()
                    _ = try await coordinator.insert(text: transcript, context: context)
                } catch {
                    presentInfoAlert(title: "Insert Failed", message: userFacingMessage(for: error))
                }
            }
        } catch {
            presentInfoAlert(title: "Insert Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func copyLastAnswer() {
        do {
            guard let answer = try historyStore.lastAnswer()?.answer else {
                presentInfoAlert(title: "No Answer", message: "No Ask Anything response has been recorded yet.")
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(answer, forType: .string)
        } catch {
            presentInfoAlert(title: "Copy Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func openHistory() {
        let events = recentHistoryEvents()

        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(
                events: events,
                refreshHandler: { [weak self] in self?.recentHistoryEvents() ?? [] },
                copyHandler: { [weak self] text in self?.copyToPasteboard(text) },
                insertHandler: { [weak self] text in self?.insertHistoryContent(text) }
            )
        }

        historyWindowController?.load(events: events)
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openAudioFileTranscription() {
        if audioFileTranscriptionWindowController == nil {
            audioFileTranscriptionWindowController = AudioFileTranscriptionWindowController { [weak self] fileURL, options in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.audioFileTranscriptionExporter.exportTranscription(
                    of: fileURL,
                    options: options
                )
            }
        }

        audioFileTranscriptionWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func insertLastAnswer() {
        do {
            guard let answer = try historyStore.lastAnswer()?.answer else {
                presentInfoAlert(title: "No Answer", message: "No Ask Anything response has been recorded yet.")
                return
            }

            Task {
                do {
                    let context = contextResolver.resolveInsertionTargetContext()
                    _ = try await coordinator.insert(text: answer, context: context)
                } catch {
                    presentInfoAlert(title: "Insert Failed", message: userFacingMessage(for: error))
                }
            }
        } catch {
            presentInfoAlert(title: "Insert Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func startDictation() {
        Task { @MainActor in
            do {
                guard activeTranscriptionTask == nil else {
                    cancelActiveDictationWorkflow()
                    return
                }
                _ = try await audioRecorder.startRecording()
                updateRecordingMenuState()
                dictationSoundPlayer.playStartCue()
                dictationOverlayController.showRecording { [weak self] in
                    self?.cancelActiveDictationWorkflow()
                }
            } catch {
                dictationOverlayController.showError(userFacingMessage(for: error))
            }
        }
    }

    private func toggleDictation() {
        if audioRecorder.isRecording {
            stopDictation()
        } else if activeTranscriptionTask != nil {
            cancelActiveDictationWorkflow()
        } else {
            startDictation()
        }
    }

    @objc
    private func stopDictation() {
        if activeTranscriptionTask != nil, !audioRecorder.isRecording {
            cancelActiveDictationWorkflow()
            return
        }

        do {
            let fileURL = try audioRecorder.stopRecording()
            updateRecordingMenuState()
            dictationSoundPlayer.playStopCue()
            dictationOverlayController.showTranscribing { [weak self] in
                self?.cancelActiveDictationWorkflow()
            }

            let task = Task { [weak self] in
                guard let self else {
                    return
                }

                do {
                    let context = contextResolver.resolveInsertionTargetContext()
                    let result = try await coordinator.transcribeAudioFile(
                        at: fileURL,
                        context: context,
                        shouldInsert: true
                    )
                    try historyStore.recordTranscript(result.transcript, context: context)
                    try? FileManager.default.removeItem(at: fileURL)
                    await MainActor.run {
                        self.activeTranscriptionTask = nil
                        self.updateRecordingMenuState()
                        self.dictationOverlayController.hide()
                    }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: fileURL)
                    await MainActor.run {
                        self.activeTranscriptionTask = nil
                        self.updateRecordingMenuState()
                        self.dictationOverlayController.showCancelled("The current dictation was cancelled.")
                    }
                } catch STTProviderError.emptyTranscript {
                    try? FileManager.default.removeItem(at: fileURL)
                    await MainActor.run {
                        self.activeTranscriptionTask = nil
                        self.updateRecordingMenuState()
                        self.dictationOverlayController.showCancelled("No speech detected.")
                    }
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    await MainActor.run {
                        self.activeTranscriptionTask = nil
                        self.updateRecordingMenuState()
                        self.dictationOverlayController.showError(self.userFacingMessage(for: error))
                    }
                }
            }
            activeTranscriptionTask = task
            updateRecordingMenuState()
        } catch {
            dictationOverlayController.showError(userFacingMessage(for: error))
        }
    }

    @objc
    private func askScreenshot() {
        quickAsk(using: .screenshot, prompt: "这张截图里的内容是什么意思？")
    }

    @objc
    private func openSetup() {
        let snapshot = currentSetupSnapshot()

        if setupWindowController == nil {
            setupWindowController = SetupWindowController(
                snapshot: snapshot,
                refreshHandler: { [weak self] in self?.refreshSetupWindow() },
                requestPermissionsHandler: { [weak self] in self?.requestPermissions() },
                requestMicrophoneHandler: { [weak self] in self?.requestMicrophonePermission() },
                requestSpeechHandler: { [weak self] in self?.requestSpeechRecognitionPermission() },
                requestAccessibilityPromptHandler: { [weak self] in self?.requestAccessibilityPermissionPrompt() },
                openMicrophoneSettingsHandler: { SystemSettingsNavigator.openMicrophonePrivacy() },
                openSpeechSettingsHandler: { SystemSettingsNavigator.openSpeechRecognitionPrivacy() },
                openAccessibilitySettingsHandler: { SystemSettingsNavigator.openAccessibilityPrivacy() },
                autoDetectSTTHandler: { [weak self] in self?.autoDetectSTT() },
                openSettingsHandler: { [weak self] in self?.openSettings() },
                openDictionaryHandler: { [weak self] in self?.openDictionaryEditor() }
            )
        }

        setupWindowController?.load(snapshot: snapshot)
        setupWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func runDoctor() {
        do {
            let loader = ConfigurationLoader()
            let configuration = try loader.load()
            let report = AppDoctor(configuration: configuration).run()
            let message = prettyPrintedJSON(report) ?? "null"
            presentInfoAlert(title: "Doctor Report", message: message)
        } catch {
            presentInfoAlert(title: "Doctor Failed", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func requestPermissions() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            _ = await PermissionManager.requestAll()
            refreshSetupWindow()
        }
    }

    private func requestMicrophonePermission() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            _ = await PermissionManager.requestMicrophonePermission()
            refreshSetupWindow()
        }
    }

    private func requestSpeechRecognitionPermission() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            _ = await PermissionManager.requestSpeechRecognitionPermission()
            refreshSetupWindow()
        }
    }

    private func requestAccessibilityPermissionPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        _ = PermissionManager.requestAccessibilityPermission()
        refreshSetupWindow()
    }

    @objc
    private func showHotkeys() {
        let message = prettyPrintedJSON(hotkeys.summaries()) ?? "null"
        presentInfoAlert(title: "Configured Hotkeys", message: message)
    }

    @objc
    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(configuration: configuration) { [weak self] request in
                self?.saveConfiguration(request)
            }
        }

        settingsWindowController?.load(configuration: configuration)
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func openDictionaryEditor() {
        let entries = resolvedDictionaryEntries()

        if dictionaryWindowController == nil {
            dictionaryWindowController = DictionaryEditorWindowController(entries: entries) { [weak self] updatedEntries in
                self?.saveDictionaryEntries(updatedEntries)
            }
        }

        dictionaryWindowController?.load(entries: entries)
        dictionaryWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func autoDetectSTT() {
        let result = STTAutodiscoverer(includeSensitiveDirectories: true).discover()

        guard result.binaryPath != nil || result.modelPath != nil else {
            presentInfoAlert(
                title: "STT Auto-Detect",
                message: "No local whisper binary or model was detected in the common search paths."
            )
            return
        }

        let updatedConfiguration = AppConfiguration(
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

        saveConfiguration(
            SettingsSaveRequest(
                configuration: updatedConfiguration,
                apiKeyChange: .unchanged
            )
        )
    }

    @objc
    private func openConfig() {
        guard !configPath.isEmpty else {
            presentInfoAlert(title: "Config Error", message: "No config path could be resolved.")
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc
    private func inspectAutoContext() {
        do {
            let context = try contextResolver.resolve(source: .auto)
            let message = prettyPrintedJSON(context) ?? "null"
            presentInfoAlert(title: "Resolved Context", message: message)
        } catch {
            presentInfoAlert(title: "Context Error", message: userFacingMessage(for: error))
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func ask(using source: ContextSource, defaultPrompt: String) {
        guard let prompt = promptForQuestion(defaultValue: defaultPrompt) else {
            return
        }

        runAsk(prompt: prompt, source: source)
    }

    private func quickAsk(using source: ContextSource, prompt: String) {
        runAsk(prompt: prompt, source: source)
    }

    private func runAsk(prompt: String, source: ContextSource) {
        Task {
            do {
                let context = try contextResolver.resolve(source: source)
                let result = try await coordinator.ask(prompt: prompt, context: context)
                try historyStore.recordAsk(prompt: prompt, result: result)
                presentAskResult(answer: result.response.answer)
            } catch {
                presentInfoAlert(title: "Ask Failed", message: userFacingMessage(for: error))
            }
        }
    }

    private func promptForQuestion(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Ask Anything"
        alert.informativeText = "Enter the question to send with the selected context."
        alert.addButton(withTitle: "Ask")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let sttError = error as? STTProviderError {
            switch sttError {
            case .emptyTranscript:
                return "No speech was detected. Check the microphone input level and try again."
            case .transcriptionTimedOut:
                return "Local speech recognition took too long and was stopped. Try a shorter dictation or switch to a smaller MLX model."
            case .missingMLXPythonPath, .missingMLXModel, .missingMLXRunnerScript:
                return "Local MLX speech recognition is not fully configured. Open Settings or run Doctor to check the MLX Python path and model."
            case .missingBinaryPath, .missingModelPath:
                return "Local whisper.cpp speech recognition is not fully configured. Open Settings or run Doctor to check the binary and model paths."
            case .commandFailed(_, let output):
                if output.localizedCaseInsensitiveContains("afconvert") ||
                    output.localizedCaseInsensitiveContains("ffmpeg") {
                    return "This audio format could not be decoded locally. Try exporting it as WAV, or install ffmpeg and retry."
                }
                if output.localizedCaseInsensitiveContains("permission") {
                    return "Speech recognition failed because a local permission or file access check failed. Run Doctor for details."
                }
                return "Local speech recognition failed. Run Doctor for details, or try a smaller model."
            case .invalidMLXResponse:
                return "Local MLX speech recognition returned an unexpected response. Try again, or switch models in Settings."
            default:
                return sttError.localizedDescription
            }
        }

        if let insertionError = error as? InsertionError {
            switch insertionError {
            case .unsupportedText:
                return "There was no text to insert."
            case .inputInjectionFailed:
                return "OmniVoice could not send the paste shortcut. Check Accessibility permission and make sure the target window is focused."
            }
        }

        return error.localizedDescription
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func insertHistoryContent(_ text: String) {
        Task {
            do {
                let context = contextResolver.resolveInsertionTargetContext()
                _ = try await coordinator.insert(text: text, context: context)
            } catch {
                presentInfoAlert(title: "Insert Failed", message: userFacingMessage(for: error))
            }
        }
    }

    private func cancelActiveDictationWorkflow() {
        if audioRecorder.isRecording {
            do {
                try audioRecorder.cancelRecording()
            } catch {
                dictationOverlayController.showError(userFacingMessage(for: error))
                return
            }

            updateRecordingMenuState()
            dictationSoundPlayer.playStopCue()
            dictationOverlayController.showCancelled("Recording cancelled.")
            return
        }

        guard let activeTranscriptionTask else {
            dictationOverlayController.hide()
            return
        }

        activeTranscriptionTask.cancel()
    }

    private func updateRecordingMenuState() {
        let isTranscribing = activeTranscriptionTask != nil
        startRecordingItem?.isEnabled = !audioRecorder.isRecording && !isTranscribing
        stopRecordingItem?.isEnabled = audioRecorder.isRecording || isTranscribing
        stopRecordingItem?.title = isTranscribing && !audioRecorder.isRecording ? "Cancel Transcription" : "Stop Dictation"

        if let button = statusItem?.button {
            if audioRecorder.isRecording {
                button.title = ""
                button.image = statusIcon(named: "waveform.circle.fill", fallback: "waveform.circle", accessibilityDescription: "OmniVoice recording")
                button.contentTintColor = .systemRed
            } else if isTranscribing {
                button.title = ""
                button.image = statusIcon(named: "waveform.badge.magnifyingglass", fallback: "waveform.circle", accessibilityDescription: "OmniVoice transcribing")
                button.contentTintColor = .systemMint
            } else {
                button.title = ""
                button.image = statusIcon(named: "waveform.circle", fallback: "waveform", accessibilityDescription: configuration.appName)
                button.contentTintColor = nil
            }
        }
    }

    private func presentAskResult(answer: String) {
        copyToPasteboard(answer)
        refreshSetupWindow()

        if let historyWindowController {
            historyWindowController.load(events: recentHistoryEvents())
            historyWindowController.showWindow(nil)
        }
    }

    private func prettyPrintedJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(value) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func saveConfiguration(_ request: SettingsSaveRequest) {
        do {
            let updated = request.configuration
            try applyAPIKeyChange(request.apiKeyChange, configuration: updated)
            let coordinator = try RuntimeFactory.makeCoordinator(
                configuration: updated,
                loader: configurationLoader
            )

            try configurationLoader.save(updated, to: configPath)
            configuration = updated
            self.coordinator = coordinator
            audioFileTranscriptionExporter = try RuntimeFactory.makeAudioFileTranscriptionExporter(
                configuration: updated,
                loader: configurationLoader
            )
            hotkeys = updated.hotkeys
            hotKeyManager.unregisterAll()
            registerHotKeys()
            refreshSetupWindow()
        } catch {
            presentInfoAlert(title: "Save Failed", message: userFacingMessage(for: error))
        }
    }

    private func saveDictionaryEntries(_ entries: [DictionaryEntry]) {
        do {
            let updatedConfiguration: AppConfiguration
            if let filePath = configuration.dictionary.filePath, !filePath.isEmpty {
                try configurationLoader.saveDictionaryEntries(entries, to: filePath)
                updatedConfiguration = configuration
            } else {
                updatedConfiguration = configuration.updatingDictionary(entries: entries)
                try configurationLoader.save(updatedConfiguration, to: configPath)
            }

            let coordinator = try RuntimeFactory.makeCoordinator(
                configuration: updatedConfiguration,
                loader: configurationLoader
            )

            configuration = updatedConfiguration
            self.coordinator = coordinator
            audioFileTranscriptionExporter = try RuntimeFactory.makeAudioFileTranscriptionExporter(
                configuration: updatedConfiguration,
                loader: configurationLoader
            )
            refreshSetupWindow()
        } catch {
            presentInfoAlert(title: "Dictionary Save Failed", message: userFacingMessage(for: error))
        }
    }

    private func resolvedDictionaryEntries() -> [DictionaryEntry] {
        do {
            return try configurationLoader.resolvedDictionaryEntries(for: configuration)
        } catch {
            return configuration.dictionary.entries
        }
    }

    private func applyAPIKeyChange(_ change: AskAPIKeyChange, configuration: AppConfiguration) throws {
        guard let service = configuration.ask.keychainService,
              let account = configuration.ask.keychainAccount else {
            return
        }

        switch change {
        case .unchanged:
            return
        case .set(let value):
            try keychainStore.writePassword(value, service: service, account: account)
        case .clear:
            try keychainStore.deletePassword(service: service, account: account)
            for legacyService in KeychainServiceCompatibility.legacyServices(for: service) {
                try keychainStore.deletePassword(service: legacyService, account: account)
            }
        }
    }

    private func refreshSetupWindow() {
        setupWindowController?.load(snapshot: currentSetupSnapshot())
        historyWindowController?.load(events: recentHistoryEvents())
    }

    private func currentSetupSnapshot() -> AppSetupSnapshot {
        let doctor = AppDoctor(configuration: configuration)
        let report = doctor.run()
        let autodiscovery = STTAutodiscoverer().discover()
        let events = recentHistoryEvents()

        return AppSetupSnapshot(
            generatedAt: report.generatedAt,
            configPath: configPath,
            sttMode: configuration.stt.mode.displayName,
            askBaseURL: configuration.ask.baseURL,
            askModel: configuration.ask.defaultModel,
            dictionaryPath: configuration.dictionary.filePath,
            historyCount: events.count,
            lastTranscriptAt: events.last(where: { $0.kind == .transcript })?.createdAt,
            lastAnswerAt: events.last(where: { $0.kind == .ask })?.createdAt,
            diagnostics: report.items,
            autodiscovery: autodiscovery
        )
    }

    private func recentHistoryEvents() -> [HistoryEvent] {
        (try? historyStore.recentEvents(limit: 100)) ?? []
    }

    private func presentSetupOnFirstLaunchIfNeeded() {
        let snapshot = currentSetupSnapshot()
        let shouldPresentSetup = snapshot.diagnostics.contains {
            switch $0.name {
            case "Microphone", "Speech Recognition", "Accessibility":
                return $0.status != .pass
            default:
                return false
            }
        }

        guard shouldPresentSetup else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            openSetup()
        }
    }
}

@MainActor
enum MenuBarApplication {
    private static var retainedDelegate: MenuBarApplicationController?

    static func run(
        configuration: AppConfiguration,
        coordinator: AppCoordinator,
        audioFileTranscriptionExporter: AudioFileTranscriptionExporter,
        configPath: String,
        contextResolver: ContextResolver,
        historyStore: HistoryStore,
        hotkeys: HotkeyConfiguration
    ) {
        let application = NSApplication.shared
        let delegate = MenuBarApplicationController(
            configuration: configuration,
            coordinator: coordinator,
            audioFileTranscriptionExporter: audioFileTranscriptionExporter,
            contextResolver: contextResolver,
            historyStore: historyStore,
            hotkeys: hotkeys,
            configPath: configPath
        )
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
