import SwiftUI

struct RootView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    @State private var selectedTab: AppTab = .dashboard
    @State private var showSplash = true
    @State private var showModeSelect = false

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
                            case .protocolDev:
                                ProtocolDevView()
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
                // Show mode selector on first launch or if not yet chosen.
                if !settings.controllerModeSelected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showModeSelect = true
                    }
                }
            }
        }
        .sheet(isPresented: $showModeSelect) {
            AppModeSelectView(isPresented: $showModeSelect)
                .environmentObject(settings)
        }
    }
}

// MARK: - App Mode Select Sheet

struct AppModeSelectView: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Image(systemName: "dial.high.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.cyan)
                    Text("Choose App Mode")
                        .font(.largeTitle.weight(.heavy))
                    Text("You can change this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(spacing: 14) {
                    ModeOptionCard(
                        title: "Standard",
                        subtitle: "Clean dashboard with real-time values. Speed, battery, temperature and ride stats — just like the stock APTUM app.",
                        icon: "gauge.with.dots.needle.bottom.50percent",
                        color: .cyan,
                        selected: settings.controllerAppMode == .standard
                    ) {
                        settings.controllerAppMode = .standard
                        isPresented = false
                    }

                    ModeOptionCard(
                        title: "Development",
                        subtitle: "All standard features plus a raw Modbus register browser (Protocol tab). Read and write any register block directly per the PDF protocol spec.",
                        icon: "tablecells",
                        color: .orange,
                        selected: settings.controllerAppMode == .development
                    ) {
                        settings.controllerAppMode = .development
                        isPresented = false
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                Button("Skip (use Standard)") {
                    settings.controllerAppMode = .standard
                    settings.controllerModeSelected = true
                    isPresented = false
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.large])
    }
}

private struct ModeOptionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 40)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(color)
                        .font(.title2)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(selected ? color.opacity(0.6) : color.opacity(0.2), lineWidth: selected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
