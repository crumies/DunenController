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
        play("startup", ext: "mp3", fallbackName: nil, fallbackExt: nil, fallbackID: 1113)
    }

    func playScanningSound(enabled: Bool) {
        guard enabled else { return }
        play("scanning", ext: "mp3", fallbackName: "scan_backup", fallbackExt: "wav", fallbackID: 1020)
    }

    func playConnectSound(enabled: Bool) {
        guard enabled else { return }
        play("connected", ext: "mp3", fallbackName: nil, fallbackExt: nil, fallbackID: 1057)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func playWarningSound(enabled: Bool = true) {
        guard enabled else { return }
        play("warning", ext: "mp3", fallbackName: "confirm_backup", fallbackExt: "wav", fallbackID: 1006)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func playConfirmSound(enabled: Bool = true) {
        guard enabled else { return }
        play("confirm", ext: "mp3", fallbackName: "confirm_backup", fallbackExt: "wav", fallbackID: 1110)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func play(_ name: String, ext: String, fallbackName: String?, fallbackExt: String?, fallbackID: SystemSoundID) {
        player?.stop()
        player = nil

        let primary = Bundle.main.url(forResource: name, withExtension: ext)
        let backup: URL? = {
            guard let fallbackName, let fallbackExt else { return nil }
            return Bundle.main.url(forResource: fallbackName, withExtension: fallbackExt)
        }()
        guard let url = primary ?? backup else {
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
