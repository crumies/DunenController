import SwiftUI

@main
struct DunenDashboardApp: App {
    @StateObject private var ble = DunenBLEManager()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(settings)
        }
    }
}
