import Foundation

public enum AppHotkeyAction: String, CaseIterable, Codable, Sendable {
    case toggleDictation
    case askSelectedText
    case askClipboard
    case askScreenshot
    case runDoctor

    public var displayName: String {
        switch self {
        case .toggleDictation:
            return "toggleDictation"
        case .askSelectedText:
            return "askSelectedText"
        case .askClipboard:
            return "askClipboard"
        case .askScreenshot:
            return "askScreenshot"
        case .runDoctor:
            return "runDoctor"
        }
    }
}

public enum HotkeyShortcutError: LocalizedError, Sendable {
    case invalidShortcut(String)
    case unsupportedKey(String)
    case emptyShortcut

    public var errorDescription: String? {
        switch self {
        case .invalidShortcut(let value):
            return "Invalid hotkey shortcut: \(value)"
        case .unsupportedKey(let value):
            return "Unsupported hotkey key token: \(value)"
        case .emptyShortcut:
            return "Hotkey shortcut must include at least one key or modifier."
        }
    }
}

public enum HotkeyShortcutParser {
    public static func parse(_ value: String) throws -> HotkeyBinding? {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        if normalized.isEmpty || normalized == "none" || normalized == "disabled" {
            return nil
        }

        let tokens = normalized.split(separator: "+").map(String.init)
        guard !tokens.isEmpty else {
            throw HotkeyShortcutError.invalidShortcut(value)
        }

        var modifiers: [HotkeyModifier] = []
        var keyCode: Int?

        for token in tokens {
            if let modifier = modifierMap[token] {
                if !modifiers.contains(modifier) {
                    modifiers.append(modifier)
                }
                continue
            }

            guard keyCode == nil else {
                throw HotkeyShortcutError.invalidShortcut(value)
            }

            guard let resolvedKeyCode = keyMap[token] else {
                throw HotkeyShortcutError.unsupportedKey(token)
            }
            keyCode = resolvedKeyCode
        }

        guard keyCode != nil || !modifiers.isEmpty else {
            throw HotkeyShortcutError.emptyShortcut
        }

        return HotkeyBinding(
            keyCode: keyCode ?? HotkeyBinding.modifierOnlyKeyCode,
            modifiers: modifiers
        )
    }

    public static func format(_ binding: HotkeyBinding?) -> String {
        guard let binding else {
            return "disabled"
        }

        let modifierTokens = binding.modifiers.map { modifier -> String in
            switch modifier {
            case .command:
                return "cmd"
            case .leftCommand:
                return "lcmd"
            case .rightCommand:
                return "rcmd"
            case .option:
                return "opt"
            case .leftOption:
                return "lopt"
            case .rightOption:
                return "ropt"
            case .control:
                return "ctrl"
            case .leftControl:
                return "lctrl"
            case .rightControl:
                return "rctrl"
            case .shift:
                return "shift"
            case .leftShift:
                return "lshift"
            case .rightShift:
                return "rshift"
            }
        }

        if binding.isModifierOnly {
            return modifierTokens.joined(separator: "+")
        }

        let keyToken = reverseKeyMap[binding.keyCode] ?? "keyCode:\(binding.keyCode)"
        return (modifierTokens + [keyToken]).joined(separator: "+")
    }

    private static let modifierMap: [String: HotkeyModifier] = [
        "cmd": .command,
        "command": .command,
        "lcmd": .leftCommand,
        "leftcmd": .leftCommand,
        "leftcommand": .leftCommand,
        "rcmd": .rightCommand,
        "rightcmd": .rightCommand,
        "rightcommand": .rightCommand,
        "opt": .option,
        "option": .option,
        "alt": .option,
        "lopt": .leftOption,
        "leftopt": .leftOption,
        "leftoption": .leftOption,
        "ropt": .rightOption,
        "rightopt": .rightOption,
        "rightoption": .rightOption,
        "ctrl": .control,
        "control": .control,
        "lctrl": .leftControl,
        "leftctrl": .leftControl,
        "leftcontrol": .leftControl,
        "rctrl": .rightControl,
        "rightctrl": .rightControl,
        "rightcontrol": .rightControl,
        "shift": .shift,
        "lshift": .leftShift,
        "leftshift": .leftShift,
        "rshift": .rightShift,
        "rightshift": .rightShift,
    ]

    private static let keyMap: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "return": 36, "enter": 36, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51,
    ]

    private static let reverseKeyMap: [Int: String] = {
        var values: [Int: String] = [:]
        for (key, value) in keyMap where values[value] == nil {
            values[value] = key
        }
        return values
    }()
}

public extension HotkeyBinding {
    func matches(keyCode: Int?, pressedSpecificModifiers: Set<HotkeyModifier>) -> Bool {
        if isModifierOnly {
            guard keyCode == nil else {
                return false
            }
        } else if self.keyCode != keyCode {
            return false
        }

        for family in [HotkeyModifierFamily.command, .option, .control, .shift] {
            let required = modifiers.filter { $0.family == family }
            let pressed = pressedSpecificModifiers.filter { $0.family == family }

            guard matchesFamily(required: required, pressed: pressed) else {
                return false
            }
        }

        return true
    }

    private func matchesFamily(required: [HotkeyModifier], pressed: Set<HotkeyModifier>) -> Bool {
        guard !required.isEmpty else {
            return pressed.isEmpty
        }

        if required.contains(where: \.isGeneric) {
            return !pressed.isEmpty
        }

        return Set(required) == pressed
    }
}

public struct HotkeySummary: Codable, Sendable {
    public let action: AppHotkeyAction
    public let shortcut: String

    public init(action: AppHotkeyAction, shortcut: String) {
        self.action = action
        self.shortcut = shortcut
    }
}

public extension HotkeyConfiguration {
    func binding(for action: AppHotkeyAction) -> HotkeyBinding? {
        switch action {
        case .toggleDictation:
            return toggleDictation
        case .askSelectedText:
            return askSelectedText
        case .askClipboard:
            return askClipboard
        case .askScreenshot:
            return askScreenshot
        case .runDoctor:
            return runDoctor
        }
    }

    func updating(_ action: AppHotkeyAction, to binding: HotkeyBinding?) -> HotkeyConfiguration {
        switch action {
        case .toggleDictation:
            return HotkeyConfiguration(
                toggleDictation: binding,
                askSelectedText: askSelectedText,
                askClipboard: askClipboard,
                askScreenshot: askScreenshot,
                runDoctor: runDoctor
            )
        case .askSelectedText:
            return HotkeyConfiguration(
                toggleDictation: toggleDictation,
                askSelectedText: binding,
                askClipboard: askClipboard,
                askScreenshot: askScreenshot,
                runDoctor: runDoctor
            )
        case .askClipboard:
            return HotkeyConfiguration(
                toggleDictation: toggleDictation,
                askSelectedText: askSelectedText,
                askClipboard: binding,
                askScreenshot: askScreenshot,
                runDoctor: runDoctor
            )
        case .askScreenshot:
            return HotkeyConfiguration(
                toggleDictation: toggleDictation,
                askSelectedText: askSelectedText,
                askClipboard: askClipboard,
                askScreenshot: binding,
                runDoctor: runDoctor
            )
        case .runDoctor:
            return HotkeyConfiguration(
                toggleDictation: toggleDictation,
                askSelectedText: askSelectedText,
                askClipboard: askClipboard,
                askScreenshot: askScreenshot,
                runDoctor: binding
            )
        }
    }

    func summaries() -> [HotkeySummary] {
        AppHotkeyAction.allCases.map { action in
            HotkeySummary(
                action: action,
                shortcut: HotkeyShortcutParser.format(binding(for: action))
            )
        }
    }
}

public extension AppConfiguration {
    func updatingHotkey(_ action: AppHotkeyAction, to binding: HotkeyBinding?) -> AppConfiguration {
        AppConfiguration(
            appName: appName,
            stt: stt,
            ask: ask,
            dictionary: dictionary,
            insertion: insertion,
            hotkeys: hotkeys.updating(action, to: binding)
        )
    }
}
