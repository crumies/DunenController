import SwiftUI

struct InfoView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    let telemetry: Telemetry

    var speedValue: Double {
        settings.speedUnit == .kmh ? telemetry.speedKmh : telemetry.speedKmh * 0.621371
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                SpeedometerView(speed: speedValue, unit: settings.speedUnit.rawValue, rpm: telemetry.rpm)
                    .frame(height: 360)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    statCard("Battery", String(format: "%.1f V", telemetry.voltage), system: "bolt.batteryblock.fill")
                    statCard("SOC", String(format: "%.0f %%", telemetry.soc), system: "battery.75percent")
                }

                HStack(spacing: 12) {
                    statCard("Controller", String(format: "%.0f °C", telemetry.controllerTemp), system: "cpu.fill")
                    statCard("Motor", String(format: "%.0f °C", telemetry.motorTemp), system: "thermometer.medium")
                }

                connectionPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 110)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DUNEN")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .tracking(3)
                Text("APTUM 8F DASHBOARD")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            Spacer()
            ConnectionPill()
        }
    }

    private var connectionPanel: some View {
        GlassCard(glow: ble.isConnected) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Connection")
                        .font(.headline)
                    Spacer()
                    Button(ble.isScanning ? "Scanning..." : "Scan") {
                        ble.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(ble.isScanning)
                }

                Text(ble.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private func statCard(_ title: String, _ value: String, system: String) -> some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.bold))
                }
                Spacer()
                Image(systemName: system)
                    .foregroundStyle(.cyan)
                    .font(.title2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct SpeedometerView: View {
    let speed: Double
    let unit: String
    let rpm: Int

    private var clamped: Double { min(max(speed, 0), 180) }

    var body: some View {
        ZStack {
            GlassCard(glow: true) {
                ZStack {
                    ForEach(0..<37) { i in
                        let angle = -135.0 + Double(i) * 270.0 / 36.0
                        Rectangle()
                            .fill(i % 3 == 0 ? .white.opacity(0.75) : .white.opacity(0.25))
                            .frame(width: i % 3 == 0 ? 3 : 1.4, height: i % 3 == 0 ? 22 : 12)
                            .offset(y: -135)
                            .rotationEffect(.degrees(angle))
                    }

                    Circle()
                        .stroke(.cyan.opacity(0.14), lineWidth: 22)
                        .frame(width: 260, height: 260)

                    Circle()
                        .trim(from: 0, to: clamped / 180 * 0.75)
                        .stroke(
                            AngularGradient(colors: [.cyan, .blue, .cyan], center: .center),
                            style: StrokeStyle(lineWidth: 22, lineCap: .round)
                        )
                        .frame(width: 260, height: 260)
                        .rotationEffect(.degrees(135))

                    VStack(spacing: 2) {
                        Text("\(Int(speed.rounded()))")
                            .font(.system(size: 78, weight: .heavy, design: .rounded))
                        Text(unit)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .trailing, spacing: 0) {
                        Text("RPM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                        Text("\(rpm)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.cyan)
                    }
                    .offset(x: 92, y: 83)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }
}
