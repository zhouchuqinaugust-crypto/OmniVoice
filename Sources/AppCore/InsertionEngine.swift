import AppKit
import Foundation

public protocol InsertionPlanning: Sendable {
    func plan(for context: InputContext?) -> InsertionPlan
}

public protocol TextInserting: Sendable {
    func insert(text: String, context: InputContext?) async throws -> InsertionPlan
}

public enum InsertionError: LocalizedError, Sendable {
    case unsupportedText
    case inputInjectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedText:
            return "Unable to insert empty text."
        case .inputInjectionFailed(let output):
            return "Failed to send paste shortcut: \(output)"
        }
    }
}

public struct InsertionEngine: InsertionPlanning, TextInserting, Sendable {
    private let configuration: InsertionConfiguration

    public init(
        configuration: InsertionConfiguration
    ) {
        self.configuration = configuration
    }

    public func plan(for context: InputContext?) -> InsertionPlan {
        guard let context, let sourceApp = context.sourceApp else {
            return configuration.localDefault
        }

        if configuration.remoteAppHints.contains(where: { sourceApp.localizedCaseInsensitiveContains($0) }) {
            return configuration.remoteDefault
        }

        return configuration.localDefault
    }

    public func insert(text: String, context: InputContext?) async throws -> InsertionPlan {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw InsertionError.unsupportedText
        }

        let insertionPlan = plan(for: context)
        let originalClipboard = captureClipboardString()

        writeClipboardString(normalized)

        if insertionPlan.delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(insertionPlan.delayMilliseconds))
        }

        try await runPasteAutomation(for: insertionPlan)

        if insertionPlan.shouldRestoreClipboard {
            restoreClipboardString(originalClipboard)
        }

        return insertionPlan
    }

    private func captureClipboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    private func writeClipboardString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func restoreClipboardString(_ value: String?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let value {
            pasteboard.setString(value, forType: .string)
        }
    }

    private func runPasteAutomation(for insertionPlan: InsertionPlan) async throws {
        let attempts = max(insertionPlan.attemptCount, 1)

        for attempt in 0..<attempts {
            do {
                try sendPasteShortcut(for: insertionPlan.mode)
            } catch {
                throw InsertionError.inputInjectionFailed(error.localizedDescription)
            }

            if attempt < attempts - 1, insertionPlan.retryIntervalMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(insertionPlan.retryIntervalMilliseconds))
            }
        }
    }

    private func sendPasteShortcut(for mode: InsertionMode) throws {
        switch mode {
        case .directAccessibility:
            try SystemInputInjector.sendCommandV()
        case .clipboardPaste, .delayedClipboardPaste, .remoteSafePaste:
            try SystemInputInjector.sendCommandV()
        }
    }
}
