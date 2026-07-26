import SwiftUI

struct ConnectionHomeView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    /// Device tapped — show vehicle selector sheet before connecting
    @State private var pendingDevice: DiscoveredBLEDevice?
    @State private var showVehicleSelector = false

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                HStack {
                    AptumLogoImage()
                        .frame(width: 170, height: 56)
                    Spacer()
                    Button("Demo") {
                        ble.setDemoMode(true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }

                Spacer(minLength: 8)

                GlassCard(glow: true) {
                    VStack(spacing: 18) {
                        AptumBikeImage()
                            .frame(height: 190)

                        Text("Connect Vehicle")
                            .font(.largeTitle.weight(.heavy))

                        Text(ble.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Pulse animation on the scan button while scanning
                        ScanButton()
                    }
                }

                if !ble.discoveredDevices.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Nearby Devices").font(.headline)
                            ForEach(ble.discoveredDevices) { device in
                                Button {
                                    pendingDevice = device
                                    showVehicleSelector = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(device.name).fontWeight(.semibold)
                                            Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Divider().opacity(0.2)
                            }
                        }
                    }
                }

                if !ble.savedDevices.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remembered Devices").font(.headline)
                            ForEach(ble.savedDevices.prefix(4)) { device in
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text("seen").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
        .sheet(isPresented: $showVehicleSelector) {
            if let device = pendingDevice {
                VehicleModelSelectorSheet(device: device) {
                    showVehicleSelector = false
                    pendingDevice = nil
                }
                .environmentObject(ble)
                .environmentObject(settings)
            }
        }
    }
}

// MARK: - Scan button with pulse animation

private struct ScanButton: View {
    @EnvironmentObject var ble: DunenBLEManager
    @State private var pulse = false

    var body: some View {
        ZStack {
            if ble.isScanning {
                Circle()
                    .stroke(Color.cyan.opacity(pulse ? 0 : 0.45), lineWidth: pulse ? 28 : 2)
                    .frame(width: 110, height: 110)
                    .scaleEffect(pulse ? 1.55 : 1.0)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
            Button(ble.isScanning ? "Scanning..." : "Scan for Devices") {
                ble.startScan()
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(ble.isScanning)
        }
        .onChange(of: ble.isScanning) { scanning in
            pulse = scanning
        }
    }
}

// MARK: - Vehicle model selector sheet

struct VehicleModelSelectorSheet: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    let device: DiscoveredBLEDevice
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        Text("Select Vehicle Model")
                            .font(.title2.weight(.heavy))
                            .padding(.top, 8)

                        Text("Choose your vehicle's power configuration. This setting is saved and only affects display limits — it does not write anything to the controller.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        ForEach(VehicleModel.allCases) { model in
                            Button {
                                settings.selectedVehicleModel = model
                            } label: {
                                GlassCard(glow: settings.selectedVehicleModel == model) {
                                    HStack(spacing: 16) {
                                        Image(systemName: model.icon)
                                            .font(.title2)
                                            .foregroundStyle(settings.selectedVehicleModel == model ? .cyan : .secondary)
                                            .frame(width: 36)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(model.rawValue)
                                                .font(.headline.weight(.bold))
                                            Text(model.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        if settings.selectedVehicleModel == model {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.cyan)
                                                .font(.title3)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Button("Connect to \(device.name)") {
                            ble.connect(to: device)
                            onDone()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        Button("Cancel") { onDone() }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
