import Foundation

enum AutomationDiagnostics {
    static func humanReadableMessage(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("-10827") {
            return "macOS blocked the UI automation event. This usually means Accessibility permission is missing, or the process is not running in an interactive desktop session. Raw output: \(trimmed)"
        }

        return trimmed
    }
}
