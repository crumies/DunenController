import SwiftUI

struct RootView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    @State private var selectedTab: AppTab = .dashboard
    @State private var showSplash = true

    var showConnection: Bool {
        !ble.isConnected && !ble.isDemoMode && !showSplash
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            ZStack(alignment: .top) {
                AppBackground()

                if showConnection {
                    ConnectionHomeView()
                } else {
                    VStack(spacing: 0) {
                        Group {
                            switch selectedTab {
                            case .dashboard:
                                DashboardView()
                            case .advanced:
                                AdvancedInfoView()
                            case .tuning:
                                TuningView()
                            case .diagnostics:
                                DiagnosticsView()
                            case .settings:
                                SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        LiquidTabBar(selectedTab: $selectedTab)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }

                if ble.isDemoMode && settings.developerUnlocked {
                    DemoDeveloperOverlay()
                        .zIndex(8)
                }

                if showSplash && settings.startupAnimation {
                    StartupSplash()
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 0.45)) {
                    showSplash = false
                }
            }
        }
    }
}
