import SwiftUI

struct StartupSplash: View {
    @State private var scale = 0.78
    @State private var glow = false
    @State private var sweep = false
    @State private var fadeText = false

    var body: some View {
        ZStack {
            AppBackground()

            Circle()
                .fill(.cyan.opacity(glow ? 0.30 : 0.09))
                .blur(radius: 105)
                .frame(width: glow ? 500 : 260)

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .trim(from: 0.05, to: 0.32)
                        .stroke(.cyan.opacity(0.16), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: CGFloat(240 + index * 70), height: CGFloat(240 + index * 70))
                        .rotationEffect(.degrees(sweep ? 360 + Double(index * 55) : Double(index * 55)))
                        .animation(.linear(duration: 3.2 + Double(index) * 0.55).repeatForever(autoreverses: false), value: sweep)
                }

                Circle()
                    .stroke(.white.opacity(glow ? 0.10 : 0.04), lineWidth: 1)
                    .frame(width: glow ? 420 : 280)
                    .animation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: glow)
            }

            VStack(spacing: 20) {
                AptumLogoImage()
                    .frame(width: 340, height: 122)
                    .scaleEffect(scale)
                    .shadow(color: .cyan.opacity(glow ? 0.58 : 0.18), radius: glow ? 36 : 12)

                Text("Connecting electric drive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan.opacity(fadeText ? 0.95 : 0.45))
            }
        }
        .onAppear {
            withAnimation(.spring(response: 1.05, dampingFraction: 0.74)) { scale = 1.0 }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { fadeText = true }
            sweep = true
        }
    }
}
