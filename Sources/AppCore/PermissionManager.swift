import AVFoundation
@preconcurrency import ApplicationServices
import Foundation
import Speech

public struct PermissionRequestReport: Codable, Sendable {
    public let generatedAt: Date
    public let microphoneStatus: String
    public let speechRecognitionStatus: String
    public let accessibilityPromptTriggered: Bool
    public let notes: [String]

    public init(
        generatedAt: Date = .now,
        microphoneStatus: String,
        speechRecognitionStatus: String,
        accessibilityPromptTriggered: Bool,
        notes: [String]
    ) {
        self.generatedAt = generatedAt
        self.microphoneStatus = microphoneStatus
        self.speechRecognitionStatus = speechRecognitionStatus
        self.accessibilityPromptTriggered = accessibilityPromptTriggered
        self.notes = notes
    }
}

public enum PermissionManager {
    public static func requestAll() async -> PermissionRequestReport {
        let microphoneStatus = await requestMicrophonePermission()
        let speechRecognitionStatus = await requestSpeechRecognitionPermission()
        let accessibilityPromptTriggered = requestAccessibilityPermission()

        return PermissionRequestReport(
            microphoneStatus: microphoneStatus,
            speechRecognitionStatus: speechRecognitionStatus,
            accessibilityPromptTriggered: accessibilityPromptTriggered,
            notes: [
                "If macOS shows a prompt, choose Allow.",
                "Speech Recognition is required for the Apple Speech fallback STT backend.",
                "Accessibility is required for text insertion, selected-text capture, and some global hotkey workflows.",
                "Automation permission for System Events may still be requested the first time an action runs."
            ]
        )
    }

    public static func requestMicrophonePermission() async -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            let granted = await Task.detached(priority: .userInitiated) {
                await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }.value
            return granted ? "authorized" : "denied"
        @unknown default:
            return "unknown"
        }
    }

    public static func requestAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func requestSpeechRecognitionPermission() async -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            let status = await Task.detached(priority: .userInitiated) {
                await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
            }.value
            return speechStatusLabel(status)
        @unknown default:
            return "unknown"
        }
    }

    nonisolated private static func speechStatusLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }
}
