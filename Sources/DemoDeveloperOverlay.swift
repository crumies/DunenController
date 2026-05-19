import SwiftUI

struct DemoDeveloperOverlay: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    @State private var offset: CGSize = CGSize(width: 18, height: 130)
    @State private var dragStart: CGSize = .zero
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Demo Controls", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                Spacer()
                Button {
                    collapsed.toggle()
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
            }

            if !collapsed {
                if settings.demoAutoInput {
                    Text("Auto demo input is enabled in Developer Options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        controlSlider("Throttle", value: $ble.demoThrottle, icon: "bolt.fill")
                        controlSlider("Brake", value: $ble.demoBrake, icon: "brakesignal")

                        Picker("Mode", selection: $ble.demoSelectedMode) {
                            ForEach(RideMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 290)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.cyan.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .cyan.opacity(0.22), radius: 18)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
                }
                .onEnded { _ in
                    dragStart = offset
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 12)
    }

    private func controlSlider(_ title: String, value: Binding<Double>, icon: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption.weight(.bold))
            }
            Slider(value: value, in: 0...1)
                .tint(.cyan)
        }
    }
}
