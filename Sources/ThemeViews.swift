import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.02, green: 0.03, blue: 0.05),
                Color(red: 0.00, green: 0.01, blue: 0.02)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            Circle()
                .fill(Color.cyan.opacity(0.18))
                .blur(radius: 90)
                .frame(width: 260, height: 260)
                .offset(x: -160, y: -300)

            Circle()
                .fill(Color.blue.opacity(0.14))
                .blur(radius: 90)
                .frame(width: 290, height: 290)
                .offset(x: 160, y: 240)
        }
    }
}

struct GlassCard<Content: View>: View {
    let content: Content
    var glow: Bool

    init(glow: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.glow = glow
    }

    var body: some View {
        content
            .padding()
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(
                        LinearGradient(colors: [
                            .white.opacity(0.24),
                            .cyan.opacity(glow ? 0.5 : 0.18),
                            .white.opacity(0.06)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: .cyan.opacity(glow ? 0.22 : 0.06), radius: glow ? 22 : 8)
    }
}

struct ConnectionPill: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ble.isConnected ? .green : (settings.demoMode ? .orange : .red))
                .frame(width: 8, height: 8)
                .shadow(color: ble.isConnected ? .green : .orange, radius: 8)

            Text(ble.isConnected ? "Connected" : (settings.demoMode ? "Demo Mode" : "Disconnected"))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

struct LiquidTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(.cyan.opacity(0.5), lineWidth: 1))
                                .shadow(color: .cyan.opacity(0.35), radius: 16)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}
