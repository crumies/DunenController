import Foundation
import AVFoundation
import AudioToolbox
import UIKit

@MainActor
final class SoundManager {
    static let shared = SoundManager()
    private var player: AVAudioPlayer?

    func playStartupSound(enabled: Bool) {
        guard enabled else { return }
        play("startup", fallbackID: 1113)
    }

    func playScanningSound(enabled: Bool) {
        guard enabled else { return }
        play("scanning", fallbackID: 1157)
    }

    func playConnectSound(enabled: Bool) {
        guard enabled else { return }
        play("connected", fallbackID: 1057)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func playWarningSound(enabled: Bool = true) {
        guard enabled else { return }
        play("warning", fallbackID: 1006)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func playConfirmSound(enabled: Bool = true) {
        guard enabled else { return }
        play("confirm", fallbackID: 1114)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func play(_ name: String, fallbackID: SystemSoundID) {
        player?.stop()
        player = nil

        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            AudioServicesPlaySystemSound(fallbackID)
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true, options: [])

            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = 1.0
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
        } catch {
            AudioServicesPlaySystemSound(fallbackID)
        }
    }
}
