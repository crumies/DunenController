import SwiftUI

struct ConnectionHomeView: View {
    @EnvironmentObject var ble: DunenBLEManager

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

                        Button(ble.isScanning ? "Scanning..." : "Scan for Devices") {
                            ble.startScan()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(ble.isScanning)
                    }
                }

                if !ble.discoveredDevices.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Nearby Devices").font(.headline)
                            ForEach(ble.discoveredDevices) { device in
                                Button { ble.connect(to: device) } label: {
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
    }
}

