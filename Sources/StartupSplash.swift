import SwiftUI

struct StartupSplash: View {
    @State private var wheelSpin = false
    @State private var lightFlash = false
    @State private var logoPulse = false

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 24) {
                Image("DunenLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(logoPulse ? 360 : 0))
                    .shadow(color: .cyan.opacity(logoPulse ? 0.8 : 0.25), radius: logoPulse ? 36 : 12)
                    .scaleEffect(logoPulse ? 1.04 : 0.96)

                ZStack {
                    Image("AptumBike")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 310)
                        .shadow(color: .cyan.opacity(0.25), radius: 20)

                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(wheelSpin ? 720 : 0))
                        .offset(x: -98, y: 72)

                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 70, height: 70)
                        .rotationEffect(.degrees(wheelSpin ? 720 : 0))
                        .offset(x: 105, y: 72)

                    Capsule()
                        .fill(.cyan.opacity(lightFlash ? 0.75 : 0.0))
                        .frame(width: 90, height: 10)
                        .blur(radius: 8)
                        .offset(x: -135, y: -12)
                }

                Text("DUNEN DASHBOARD")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)

                Text("Connecting to FFE0")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                wheelSpin = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                logoPulse = true
            }
            withAnimation(.easeInOut(duration: 0.18).repeatCount(4, autoreverses: true).delay(0.45)) {
                lightFlash = true
            }
        }
    }
}
