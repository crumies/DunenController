import SwiftUI

struct ContentView: View {
    @StateObject private var bluetooth = DunenBLEManager()
    @StateObject private var sensors = RideSensorManager()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    statusCard

                    HStack(spacing: 12) {
                        metricCard(title: "GPS Speed", value: String(format: "%.1f", sensors.speedKmh), unit: "km/h")
                        metricCard(title: "Max Speed", value: String(format: "%.1f", sensors.maxSpeedKmh), unit: "km/h")
                    }

                    HStack(spacing: 12) {
                        metricCard(title: "Tilt", value: String(format: "%.1f", sensors.rollDegrees), unit: "°")
                        metricCard(title: "G-Force", value: String(format: "%.2f", sensors.gForce), unit: "g")
                    }

                    blePacketCard
                    deviceListCard
                }
                .padding()
            }
            .navigationTitle("DUNEN Dashboard")
            .onAppear { sensors.start() }
            .onDisappear { sensors.stop() }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controller").font(.headline)
            Text(bluetooth.connectionStatus).font(.subheadline)

            HStack {
                Button(bluetooth.isScanning ? "Scanning..." : "Scan") {
                    bluetooth.startScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bluetooth.isScanning)

                Button("Disconnect") {
                    bluetooth.disconnect()
                }
                .buttonStyle(.bordered)
                .disabled(!bluetooth.isConnected)
            }

            if let name = bluetooth.connectedName {
                Text("Connected: \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var blePacketCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live BLE Raw Packets").font(.headline)
            Text("Service: FFE0 / Characteristic: FFE1")
                .font(.caption)
                .foregroundStyle(.secondary)

            if bluetooth.latestHex.isEmpty {
                Text("No packets yet. Connect and turn bike/controller on.")
                    .foregroundStyle(.secondary)
            } else {
                Text(bluetooth.latestHex)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !bluetooth.packetLog.isEmpty {
                Text("Recent packets").font(.subheadline)
                ForEach(bluetooth.packetLog.prefix(8), id: \.self) { packet in
                    Text(packet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .cardStyle()
    }

    private var deviceListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Found Devices").font(.headline)

            if bluetooth.discoveredDevices.isEmpty {
                Text("No devices found yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.discoveredDevices) { device in
                    Button {
                        bluetooth.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.subheadline)
                                Text(device.id.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private func metricCard(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
