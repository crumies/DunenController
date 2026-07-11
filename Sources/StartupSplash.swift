import SwiftUI

struct StartupSplash: View {
    @State private var show = false

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 14) {
                AptumLogoImage()
                    .frame(width: 360, height: 125)
                    .scaleEffect(show ? 1.0 : 0.82)
                    .opacity(show ? 1.0 : 0.0)
                    .shadow(color: .cyan.opacity(show ? 0.42 : 0.0), radius: 28)

                Text("Always Progressing Toward Ultimate Mobility")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .tracking(1.35)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.cyan.opacity(show ? 0.92 : 0.0))
                    .padding(.horizontal, 24)

                Text("Connecting electric drive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(show ? 0.9 : 0.0))
                    .padding(.top, 4)
            }
            .animation(.easeOut(duration: 0.85), value: show)
        }
        .onAppear {
            show = true
        }
    }
}
