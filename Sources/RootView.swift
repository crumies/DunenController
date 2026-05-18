import SwiftUI

struct RootView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    @State private var selectedTab: AppTab = .info
    @State private var showSplash = true

    var displayTelemetry: Telemetry {
        settings.demoMode && !ble.isConnected ? .demo : ble.telemetry
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .info:
                        InfoView(telemetry: displayTelemetry)
                    case .advanced:
                        AdvancedView(telemetry: displayTelemetry)
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                LiquidTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if showSplash && settings.startupAnimation {
                StartupSplash()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.35) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    showSplash = false
                }
            }
        }
    }
}
