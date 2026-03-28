import AppKit
import Foundation

@MainActor
final class DictationSoundPlayer {
    private let startCue = DictationSoundPlayer.loadSound(named: "Glass", volume: 0.40)
    private let stopCue = DictationSoundPlayer.loadSound(named: "Pop", volume: 0.45)

    func playStartCue() {
        startCue?.stop()
        startCue?.play()
    }

    func playStopCue() {
        stopCue?.stop()
        stopCue?.play()
    }

    private static func loadSound(named name: String, volume: Float) -> NSSound? {
        let candidates = [
            URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff"),
            URL(fileURLWithPath: "/System/Library/Sounds/\(name).caf"),
        ]

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            return nil
        }

        sound.volume = volume
        return sound
    }
}
