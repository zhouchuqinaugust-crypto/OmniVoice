import AppCore
import AppKit
import Foundation

@MainActor
struct AppSetupSnapshot {
    let generatedAt: Date
    let configPath: String
    let sttMode: String
    let askBaseURL: String
    let askModel: String
    let dictionaryPath: String?
    let historyCount: Int
    let lastTranscriptAt: Date?
    let lastAnswerAt: Date?
    let diagnostics: [DiagnosticItem]
    let autodiscovery: STTAutodiscoveryResult
}

@MainActor
final class SetupWindowController: NSWindowController {
    private let refreshHandler: () -> Void
    private let requestPermissionsHandler: () -> Void
    private let requestMicrophoneHandler: () -> Void
    private let requestSpeechHandler: () -> Void
    private let requestAccessibilityPromptHandler: () -> Void
    private let openMicrophoneSettingsHandler: () -> Void
    private let openSpeechSettingsHandler: () -> Void
    private let openAccessibilitySettingsHandler: () -> Void
    private let autoDetectSTTHandler: () -> Void
    private let openSettingsHandler: () -> Void
    private let openDictionaryHandler: () -> Void

    private let generatedAtLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let historyLabel = NSTextField(wrappingLabelWithString: "")
    private let autodetectLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsStack = NSStackView()

    init(
        snapshot: AppSetupSnapshot,
        refreshHandler: @escaping () -> Void,
        requestPermissionsHandler: @escaping () -> Void,
        requestMicrophoneHandler: @escaping () -> Void,
        requestSpeechHandler: @escaping () -> Void,
        requestAccessibilityPromptHandler: @escaping () -> Void,
        openMicrophoneSettingsHandler: @escaping () -> Void,
        openSpeechSettingsHandler: @escaping () -> Void,
        openAccessibilitySettingsHandler: @escaping () -> Void,
        autoDetectSTTHandler: @escaping () -> Void,
        openSettingsHandler: @escaping () -> Void,
        openDictionaryHandler: @escaping () -> Void
    ) {
        self.refreshHandler = refreshHandler
        self.requestPermissionsHandler = requestPermissionsHandler
        self.requestMicrophoneHandler = requestMicrophoneHandler
        self.requestSpeechHandler = requestSpeechHandler
        self.requestAccessibilityPromptHandler = requestAccessibilityPromptHandler
        self.openMicrophoneSettingsHandler = openMicrophoneSettingsHandler
        self.openSpeechSettingsHandler = openSpeechSettingsHandler
        self.openAccessibilitySettingsHandler = openAccessibilitySettingsHandler
        self.autoDetectSTTHandler = autoDetectSTTHandler
        self.openSettingsHandler = openSettingsHandler
        self.openDictionaryHandler = openDictionaryHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Setup"
        window.center()
        super.init(window: window)
        buildInterface()
        load(snapshot: snapshot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(snapshot: AppSetupSnapshot) {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        let generatedAt = DateFormatter.localizedString(
            from: snapshot.generatedAt,
            dateStyle: .medium,
            timeStyle: .medium
        )

        generatedAtLabel.stringValue = "Last refreshed: \(generatedAt)"
        summaryLabel.stringValue = [
            "STT mode: \(snapshot.sttMode)",
            "Ask base URL: \(snapshot.askBaseURL)",
            "Ask model: \(snapshot.askModel)",
            "Config path: \(snapshot.configPath)",
            "Dictionary path: \(snapshot.dictionaryPath ?? "inline entries only")",
        ].joined(separator: "\n")

        let lastTranscript = snapshot.lastTranscriptAt.map { formatter.localizedString(for: $0, relativeTo: .now) } ?? "none"
        let lastAnswer = snapshot.lastAnswerAt.map { formatter.localizedString(for: $0, relativeTo: .now) } ?? "none"
        historyLabel.stringValue = "History events: \(snapshot.historyCount)\nLast transcript: \(lastTranscript)\nLast Ask answer: \(lastAnswer)"

        let binaryLine = snapshot.autodiscovery.binaryPath ?? "none found"
        let modelLine = snapshot.autodiscovery.modelPath ?? "none found"
        autodetectLabel.stringValue = "Auto-detected STT binary: \(binaryLine)\nAuto-detected STT model: \(modelLine)"

        diagnosticsStack.arrangedSubviews.forEach {
            diagnosticsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        snapshot.diagnostics.forEach { item in
            diagnosticsStack.addArrangedSubview(diagnosticRow(item))
        }
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        generatedAtLabel.font = .systemFont(ofSize: 12, weight: .medium)
        generatedAtLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 0
        historyLabel.maximumNumberOfLines = 0
        autodetectLabel.maximumNumberOfLines = 0
        autodetectLabel.textColor = .secondaryLabelColor

        diagnosticsStack.orientation = .vertical
        diagnosticsStack.spacing = 10
        diagnosticsStack.alignment = .leading

        let diagnosticsScrollView = NSScrollView()
        diagnosticsScrollView.hasVerticalScroller = true
        diagnosticsScrollView.drawsBackground = false
        diagnosticsScrollView.documentView = diagnosticsStack
        diagnosticsScrollView.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let permissionsButton = NSButton(title: "Request Permissions", target: self, action: #selector(requestPermissions))
        let requestMicButton = NSButton(title: "Request Mic", target: self, action: #selector(requestMicrophone))
        let requestSpeechButton = NSButton(title: "Request Speech", target: self, action: #selector(requestSpeech))
        let requestAccessibilityButton = NSButton(title: "Prompt Accessibility", target: self, action: #selector(requestAccessibilityPrompt))
        let microphoneSettingsButton = NSButton(title: "Open Mic Settings", target: self, action: #selector(openMicrophoneSettings))
        let speechSettingsButton = NSButton(title: "Open Speech Settings", target: self, action: #selector(openSpeechSettings))
        let accessibilitySettingsButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        let detectButton = NSButton(title: "Auto-Detect STT", target: self, action: #selector(autoDetectSTT))
        let settingsButton = NSButton(title: "Settings", target: self, action: #selector(openSettings))
        let dictionaryButton = NSButton(title: "Dictionary", target: self, action: #selector(openDictionary))

        let buttonRow = NSStackView(views: [
            refreshButton,
            permissionsButton,
            requestMicButton,
            requestSpeechButton,
            requestAccessibilityButton,
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let buttonRow2 = NSStackView(views: [
            microphoneSettingsButton,
            speechSettingsButton,
            accessibilitySettingsButton,
        ])
        buttonRow2.orientation = .horizontal
        buttonRow2.spacing = 10

        let buttonRow3 = NSStackView(views: [
            detectButton,
            settingsButton,
            dictionaryButton,
        ])
        buttonRow3.orientation = .horizontal
        buttonRow3.spacing = 10

        root.addArrangedSubview(generatedAtLabel)
        root.addArrangedSubview(summaryLabel)
        root.addArrangedSubview(historyLabel)
        root.addArrangedSubview(autodetectLabel)
        root.addArrangedSubview(buttonRow)
        root.addArrangedSubview(buttonRow2)
        root.addArrangedSubview(buttonRow3)
        root.addArrangedSubview(diagnosticsScrollView)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            diagnosticsStack.widthAnchor.constraint(equalTo: diagnosticsScrollView.contentView.widthAnchor),
        ])

        window.contentView = container
    }

    @objc
    private func refresh() {
        refreshHandler()
    }

    @objc
    private func requestPermissions() {
        requestPermissionsHandler()
    }

    @objc
    private func requestMicrophone() {
        requestMicrophoneHandler()
    }

    @objc
    private func requestSpeech() {
        requestSpeechHandler()
    }

    @objc
    private func requestAccessibilityPrompt() {
        requestAccessibilityPromptHandler()
    }

    @objc
    private func openMicrophoneSettings() {
        openMicrophoneSettingsHandler()
    }

    @objc
    private func openSpeechSettings() {
        openSpeechSettingsHandler()
    }

    @objc
    private func openAccessibilitySettings() {
        openAccessibilitySettingsHandler()
    }

    @objc
    private func autoDetectSTT() {
        autoDetectSTTHandler()
    }

    @objc
    private func openSettings() {
        openSettingsHandler()
    }

    @objc
    private func openDictionary() {
        openDictionaryHandler()
    }

    private func diagnosticRow(_ item: DiagnosticItem) -> NSView {
        let statusLabel = NSTextField(labelWithString: item.status.rawValue.uppercased())
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = color(for: item.status)

        let messageLabel = NSTextField(wrappingLabelWithString: "\(item.name): \(item.message)")
        messageLabel.maximumNumberOfLines = 0

        let row = NSStackView(views: [statusLabel, messageLabel])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    private func color(for status: DiagnosticStatus) -> NSColor {
        switch status {
        case .pass:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .fail:
            return .systemRed
        }
    }
}
