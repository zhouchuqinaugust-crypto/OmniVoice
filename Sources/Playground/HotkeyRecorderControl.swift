import AppCore
import AppKit
import Foundation

@MainActor
final class HotkeyRecorderControl: NSView {
    var binding: HotkeyBinding? {
        didSet {
            updateUI()
        }
    }

    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    private var isRecording = false {
        didSet {
            updateUI()
        }
    }

    private var pendingSpecificModifiers: Set<HotkeyModifier> = [] {
        didSet {
            if isRecording {
                previewLabel?.stringValue = previewText()
            }
        }
    }

    private var localMonitor: Any?
    private weak var recorderWindow: NSWindow?
    private weak var previewLabel: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildInterface()
        updateUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildInterface() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        recordButton.target = self
        recordButton.action = #selector(beginRecording)
        recordButton.bezelStyle = .rounded
        recordButton.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        clearButton.target = self
        clearButton.action = #selector(clearBinding)
        clearButton.bezelStyle = .rounded
        clearButton.font = .systemFont(ofSize: 12, weight: .regular)

        stack.addArrangedSubview(recordButton)
        stack.addArrangedSubview(clearButton)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc
    private func beginRecording() {
        guard !isRecording else {
            cancelRecording()
            return
        }

        guard let parentWindow = window else {
            NSSound.beep()
            return
        }

        pendingSpecificModifiers.removeAll()
        isRecording = true

        let recorderWindow = makeRecorderWindow()
        self.recorderWindow = recorderWindow
        installMonitorIfNeeded()

        parentWindow.beginSheet(recorderWindow) { [weak self] _ in
            self?.teardownRecordingUI()
        }
    }

    @objc
    private func clearBinding() {
        binding = nil
        cancelRecording()
    }

    private func makeRecorderWindow() -> NSWindow {
        let recorderWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        recorderWindow.title = "Record Shortcut"
        recorderWindow.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Press the shortcut now")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let previewLabel = NSTextField(labelWithString: previewText())
        previewLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        previewLabel.textColor = .controlAccentColor
        previewLabel.alignment = .center
        previewLabel.lineBreakMode = .byTruncatingMiddle
        self.previewLabel = previewLabel

        let hintLabel = NSTextField(wrappingLabelWithString: "For modifier-only shortcuts, press the modifiers and release one of them to confirm. Press Delete to clear the shortcut, or Escape to cancel.")
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, previewLabel, hintLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        recorderWindow.contentView = contentView
        return recorderWindow
    }

    private func installMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.isRecording else {
                return event
            }

            switch event.type {
            case .flagsChanged:
                self.handleModifierEvent(event)
                return nil
            case .keyDown:
                return self.handleKeyDown(event) ? nil : event
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 51:
            binding = nil
            finishRecording()
            return true
        case 53:
            cancelRecording()
            return true
        default:
            binding = HotkeyBinding(
                keyCode: Int(event.keyCode),
                modifiers: resolvedModifiers(for: event)
            )
            finishRecording()
            return true
        }
    }

    private func finishRecording() {
        closeRecorderWindow()
    }

    private func cancelRecording() {
        closeRecorderWindow()
    }

    private func closeRecorderWindow() {
        guard let recorderWindow else {
            teardownRecordingUI()
            return
        }

        if let parentWindow = recorderWindow.sheetParent {
            parentWindow.endSheet(recorderWindow)
        } else {
            recorderWindow.close()
            teardownRecordingUI()
        }
    }

    private func teardownRecordingUI() {
        removeMonitor()
        previewLabel = nil
        recorderWindow = nil
        pendingSpecificModifiers.removeAll()
        isRecording = false
    }

    private func updatePendingModifiers(from event: NSEvent) {
        guard let descriptor = modifierDescriptor(for: event.keyCode) else {
            return
        }

        if event.modifierFlags.contains(descriptor.flagsMask) {
            pendingSpecificModifiers.insert(descriptor.modifier)
        } else {
            pendingSpecificModifiers.remove(descriptor.modifier)
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        let previousModifiers = pendingSpecificModifiers
        updatePendingModifiers(from: event)

        if previousModifiers.count > pendingSpecificModifiers.count, !previousModifiers.isEmpty {
            binding = HotkeyBinding(
                keyCode: HotkeyBinding.modifierOnlyKeyCode,
                modifiers: Array(previousModifiers)
            )
            finishRecording()
        }
    }

    private func resolvedModifiers(for event: NSEvent) -> [HotkeyModifier] {
        var modifiers = pendingSpecificModifiers

        if !modifiers.contains(where: { $0.family == .command }), event.modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }

        if !modifiers.contains(where: { $0.family == .option }), event.modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }

        if !modifiers.contains(where: { $0.family == .control }), event.modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }

        if !modifiers.contains(where: { $0.family == .shift }), event.modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }

        return Array(modifiers)
    }

    private func previewText() -> String {
        let previewBinding = HotkeyBinding(keyCode: -1, modifiers: Array(pendingSpecificModifiers))
        let formatted = HotkeyShortcutParser.format(previewBinding)
        return formatted.isEmpty ? "..." : formatted
    }

    private func updateUI() {
        if isRecording {
            recordButton.title = "Recording..."
            recordButton.contentTintColor = .controlAccentColor
        } else {
            recordButton.title = binding.map(HotkeyShortcutParser.format) ?? "Record Shortcut"
            recordButton.contentTintColor = nil
        }

        clearButton.isEnabled = binding != nil
    }

    private func modifierDescriptor(for keyCode: UInt16) -> ModifierDescriptor? {
        switch keyCode {
        case 54:
            return ModifierDescriptor(modifier: .rightCommand, flagsMask: .command)
        case 55:
            return ModifierDescriptor(modifier: .leftCommand, flagsMask: .command)
        case 58:
            return ModifierDescriptor(modifier: .leftOption, flagsMask: .option)
        case 59:
            return ModifierDescriptor(modifier: .leftControl, flagsMask: .control)
        case 60:
            return ModifierDescriptor(modifier: .rightShift, flagsMask: .shift)
        case 61:
            return ModifierDescriptor(modifier: .rightOption, flagsMask: .option)
        case 62:
            return ModifierDescriptor(modifier: .rightControl, flagsMask: .control)
        case 56:
            return ModifierDescriptor(modifier: .leftShift, flagsMask: .shift)
        default:
            return nil
        }
    }
}

private struct ModifierDescriptor {
    let modifier: HotkeyModifier
    let flagsMask: NSEvent.ModifierFlags
}
