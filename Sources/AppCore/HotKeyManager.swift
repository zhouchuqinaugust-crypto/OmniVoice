import AppKit
import Foundation

public enum HotKeyError: LocalizedError {
    case duplicateRegistration(HotkeyBinding)

    public var errorDescription: String? {
        switch self {
        case .duplicateRegistration(let binding):
            return "A global hotkey is already registered for \(HotkeyShortcutParser.format(binding))."
        }
    }
}

@MainActor
public final class HotKeyManager {
    private struct Registration {
        let binding: HotkeyBinding
        let handler: () -> Void
    }

    private struct TriggerSignature: Equatable {
        let keyCode: Int?
        let modifiers: Set<HotkeyModifier>
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pressedSpecificModifiers: Set<HotkeyModifier> = []
    private var lastTriggerSignature: TriggerSignature?
    private var modifierChordUsedNonModifierKey = false
    private var modifierChordConsumed = false

    public init() {
        installMonitorsIfNeeded()
    }

    public func register(_ binding: HotkeyBinding, handler: @escaping () -> Void) throws {
        if registrations.values.contains(where: { $0.binding == binding }) {
            throw HotKeyError.duplicateRegistration(binding)
        }

        installMonitorsIfNeeded()
        registrations[nextID] = Registration(binding: binding, handler: handler)
        nextID += 1
    }

    public func unregisterAll() {
        registrations.removeAll()
        pressedSpecificModifiers.removeAll()
        lastTriggerSignature = nil
        modifierChordUsedNonModifierKey = false
        modifierChordConsumed = false
    }

    private func installMonitorsIfNeeded() {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleGlobalEvent(event)
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        process(event)
        return event
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        process(event)
    }

    private func process(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let previousModifiers = pressedSpecificModifiers
            updatePressedModifiers(from: event)
            handleModifierTransition(from: previousModifiers, to: pressedSpecificModifiers)

            if pressedSpecificModifiers.isEmpty {
                lastTriggerSignature = nil
            }
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            if lastTriggerSignature?.keyCode == Int(event.keyCode) {
                lastTriggerSignature = nil
            }
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if !pressedSpecificModifiers.isEmpty {
            modifierChordUsedNonModifierKey = true
        }

        let signature = TriggerSignature(
            keyCode: Int(event.keyCode),
            modifiers: pressedSpecificModifiers
        )

        guard signature != lastTriggerSignature else {
            return
        }

        let matchingHandlers = registrations.values
            .filter { $0.binding.matches(keyCode: signature.keyCode, pressedSpecificModifiers: signature.modifiers) }
            .map(\.handler)

        guard !matchingHandlers.isEmpty else {
            return
        }

        lastTriggerSignature = signature
        if !pressedSpecificModifiers.isEmpty {
            modifierChordConsumed = true
        }
        matchingHandlers.forEach { $0() }
    }

    private func handleModifierTransition(from previousModifiers: Set<HotkeyModifier>, to currentModifiers: Set<HotkeyModifier>) {
        if previousModifiers.isEmpty, !currentModifiers.isEmpty {
            modifierChordUsedNonModifierKey = false
            modifierChordConsumed = false
        }

        if currentModifiers.count < previousModifiers.count {
            triggerModifierOnlyHandlers(for: previousModifiers)
        }

        if currentModifiers.isEmpty {
            modifierChordUsedNonModifierKey = false
            modifierChordConsumed = false
        }
    }

    private func triggerModifierOnlyHandlers(for modifiers: Set<HotkeyModifier>) {
        guard !modifiers.isEmpty,
              !modifierChordUsedNonModifierKey,
              !modifierChordConsumed else {
            return
        }

        let signature = TriggerSignature(
            keyCode: nil,
            modifiers: modifiers
        )

        guard signature != lastTriggerSignature else {
            return
        }

        let matchingHandlers = registrations.values
            .filter { $0.binding.isModifierOnly && $0.binding.matches(keyCode: nil, pressedSpecificModifiers: signature.modifiers) }
            .map(\.handler)

        guard !matchingHandlers.isEmpty else {
            return
        }

        lastTriggerSignature = signature
        modifierChordConsumed = true
        matchingHandlers.forEach { $0() }
    }

    private func updatePressedModifiers(from event: NSEvent) {
        guard let descriptor = modifierDescriptor(for: event.keyCode) else {
            return
        }

        if event.modifierFlags.contains(descriptor.flagsMask) {
            pressedSpecificModifiers.insert(descriptor.modifier)
        } else {
            pressedSpecificModifiers.remove(descriptor.modifier)
        }
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
