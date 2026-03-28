import AppKit
import Foundation

@MainActor
enum SystemSettingsNavigator {
    static func openMicrophonePrivacy() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechRecognitionPrivacy() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    static func openAccessibilityPrivacy() {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func openSettingsURL(_ value: String) {
        guard let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
