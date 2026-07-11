import SwiftUI

struct AppBackground: View {
    @Environment(\.colorScheme) var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                ? [Color(red: 0.02, green: 0.03, blue: 0.05), .black]
                : [Color(red: 0.92, green: 0.97, blue: 1.0), .white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle().fill(.cyan.opacity(0.16)).blur(radius: 90).frame(width: 280).offset(x: -150, y: -290)
            Circle().fill(.blue.opacity(0.12)).blur(radius: 90).frame(width: 300).offset(x: 160, y: 240)
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
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.cyan.opacity(glow ? 0.50 : 0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: .cyan.opacity(glow ? 0.24 : 0.06), radius: glow ? 22 : 8)
    }
}

struct ConnectionPill: View {
    @EnvironmentObject var ble: DunenBLEManager
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ble.isConnected ? .green : (ble.isDemoMode ? .orange : .red)).frame(width: 8, height: 8)
            Text(ble.isConnected ? "Connected" : (ble.isDemoMode ? "Demo" : "Offline")).font(.caption.weight(.semibold))
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
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 16, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selectedTab == tab {
                            Capsule().fill(.ultraThinMaterial).overlay(Capsule().stroke(.cyan.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .background(.ultraThinMaterial)
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}

struct MiniLineGraph: View {
    let values: [Double]
    var maxValue: Double? = nil

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let maxV = max(maxValue ?? (values.max() ?? 1), 1)
                let minV = min(values.min() ?? 0, 0)
                let range = max(maxV - minV, 1)
                for idx in values.indices {
                    let x = geo.size.width * CGFloat(idx) / CGFloat(values.count - 1)
                    let y = geo.size.height - (geo.size.height * CGFloat((values[idx] - minV) / range))
                    if idx == values.startIndex { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: .cyan.opacity(0.45), radius: 8)
        }
    }
}


struct ToastView: View {
    let toast: AppToast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(.cyan)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.headline)
                Text(toast.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.cyan.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .cyan.opacity(0.18), radius: 18)
        .padding(.horizontal, 18)
    }
}


struct StyledConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let systemImage: String
    let destructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(destructive ? .orange : .cyan)

                Text(title)
                    .font(.title3.weight(.heavy))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(cancelTitle) {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button(confirmTitle) {
                        onConfirm()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(destructive ? .orange : .cyan)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 330)
            .background(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke((destructive ? Color.orange : Color.cyan).opacity(0.45), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: (destructive ? Color.orange : Color.cyan).opacity(0.22), radius: 24)
            .padding(.horizontal, 24)
        }
    }
}
