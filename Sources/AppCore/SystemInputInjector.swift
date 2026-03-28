import ApplicationServices
import Foundation

public enum SystemInputInjectionError: LocalizedError, Sendable {
    case accessibilityUnavailable
    case eventSourceUnavailable
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable:
            return "Accessibility permission is required for synthetic keyboard input."
        case .eventSourceUnavailable:
            return "Unable to create a keyboard event source."
        case .eventCreationFailed:
            return "Unable to create keyboard events for system input."
        }
    }
}

public enum SystemInputInjector {
    public static func sendCommandV() throws {
        try sendShortcut(keyCode: 9, modifierKeyCodes: [55], modifierFlags: .maskCommand)
    }

    public static func sendCommandC() throws {
        try sendShortcut(keyCode: 8, modifierKeyCodes: [55], modifierFlags: .maskCommand)
    }

    private static func sendShortcut(
        keyCode: CGKeyCode,
        modifierKeyCodes: [CGKeyCode],
        modifierFlags: CGEventFlags
    ) throws {
        guard AXIsProcessTrusted() else {
            throw SystemInputInjectionError.accessibilityUnavailable
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SystemInputInjectionError.eventSourceUnavailable
        }

        let modifierDownEvents = try modifierKeyCodes.map { modifierKeyCode in
            try makeEvent(source: source, keyCode: modifierKeyCode, isKeyDown: true, flags: modifierFlags)
        }

        let keyDownEvent = try makeEvent(source: source, keyCode: keyCode, isKeyDown: true, flags: modifierFlags)
        let keyUpEvent = try makeEvent(source: source, keyCode: keyCode, isKeyDown: false, flags: modifierFlags)

        let modifierUpEvents = try modifierKeyCodes.reversed().map { modifierKeyCode in
            try makeEvent(source: source, keyCode: modifierKeyCode, isKeyDown: false, flags: [])
        }

        (modifierDownEvents + [keyDownEvent, keyUpEvent] + modifierUpEvents).forEach {
            $0.post(tap: .cghidEventTap)
        }
    }

    private static func makeEvent(
        source: CGEventSource,
        keyCode: CGKeyCode,
        isKeyDown: Bool,
        flags: CGEventFlags
    ) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: isKeyDown
        ) else {
            throw SystemInputInjectionError.eventCreationFailed
        }

        event.flags = flags
        return event
    }
}
