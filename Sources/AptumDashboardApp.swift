import UIKit
import AudioToolbox
import SwiftUI
import AVFoundation

@main
struct AptumDashboardApp: App {
    @StateObject private var ble = DunenBLEManager()
    @StateObject private var tuning = TuningStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var gps = GPSSpeedManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(tuning)
                .environmentObject(settings)
                .environmentObject(gps)
                .preferredColorScheme(settings.colorScheme)
                .onAppear {
                    if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                    SoundManager.shared.playStartupSound(enabled: settings.startupSound)
                    ble.attachTuningStore(tuning)
                    ble.attachSettings(settings)
                    tuning.loadLocalBackup()
                }
        }
    }
}
