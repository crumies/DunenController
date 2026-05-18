import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: DunenBLEManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Settings")
                            .font(.largeTitle.weight(.heavy))
                        Text("Speed unit, demo mode and connection")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    AptumLogoImage()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Speed Unit")
                            .font(.headline)

                        Picker("Speed", selection: Binding(
                            get: { settings.speedUnit },
                            set: { settings.speedUnit = $0 }
                        )) {
                            ForEach(SpeedUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Odometer follows this setting automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard(glow: settings.demoMode) {
                    VStack(spacing: 16) {
                        Toggle("Demo Mode", isOn: $settings.demoMode)
                            .tint(.cyan)
                        Text("Shows fake AP8F values when the controller is not connected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GlassCard {
                    VStack(spacing: 16) {
                        Toggle("Startup animation", isOn: $settings.startupAnimation)
                            .tint(.cyan)

                        Toggle("Show raw packet logger", isOn: $settings.showRawPackets)
                            .tint(.cyan)

                        Toggle("Auto reconnect preference", isOn: $settings.autoReconnect)
                            .tint(.cyan)

                        VStack(alignment: .leading) {
                            Text("Glow intensity")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $settings.glowIntensity, in: 0...1)
                                .tint(.cyan)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connection")
                            .font(.headline)
                        Text(ble.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button(ble.isScanning ? "Scanning..." : "Scan APTUM") {
                                ble.startScan()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(ble.isScanning)

                            Button("Disconnect") {
                                ble.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!ble.isConnected)
                        }

                        ForEach(ble.discoveredDevices) { device in
                            Button {
                                ble.connect(to: device)
                            } label: {
                                HStack {
                                    Text(device.name)
                                    Spacer()
                                    Text("\(device.rssi) dBm").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.2)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                        Text("Aptum Dashboard Read-Only Pro")
                        Text("For Aptum 8F / APTUM FFE0 BLE controllers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("No tuning/write controls included.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 112)
        }
    }
}
