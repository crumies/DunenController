import SwiftUI

struct AdvancedInfoView: View {
    @EnvironmentObject var ble: DunenBLEManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                title("Advanced Info", "Live calculated controller data")

                GlassCard(glow: true) {
                    VStack(spacing: 12) {
                        row("RPM", "\(ble.telemetry.rpm)")
                        row("Voltage", String(format: "%.1f V", ble.telemetry.voltage))
                        row("Current", String(format: "%.1f A", ble.telemetry.currentA))
                        row("Power", String(format: "%.1f kW", ble.telemetry.powerKw))
                        row("WarningCode", "\(ble.telemetry.warningCode)")
                        row("ErrCode", "\(ble.telemetry.errorCode)")
                    }
                }

                GlassCard {
                    VStack(spacing: 12) {
                        row("Lean Estimate", String(format: "%.1f°", ble.telemetry.leanAngle))
                        row("G-Force Estimate", String(format: "%.2f g", ble.telemetry.gForce))
                        row("Wheel RPM", String(format: "%.0f rpm", ble.telemetry.wheelRPM))
                        row("Wheel Torque Est.", String(format: "%.1f Nm", ble.telemetry.wheelTorqueNm))
                        row("Theoretical Top", String(format: "%.0f km/h", ble.telemetry.theoreticalTopSpeedKmh))
                    }
                }

                GlassCard {
                    VStack(spacing: 12) {
                        row("Battery % Est.", String(format: "%.0f %%", ble.telemetry.batteryPercent))
                        row("Voltage Sag", String(format: "%.2f V", ble.telemetry.voltageSag))
                        row("Motor Temp", String(format: "%.1f °C", ble.telemetry.motorTemp))
                        row("Controller Temp", String(format: "%.1f °C", ble.telemetry.controllerTemp))
                        heatBar(value: ble.telemetry.controllerTemp)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chain Drive Setup")
                            .font(.headline)
                        row("Battery", "72V 38.4Ah")
                        row("Motor", "4000W / 8000W peak")
                        row("Rear sprocket", "48T")
                        row("Rear wheel", "18 inch")
                        row("Front wheel", "19 inch")
                        row("Drive", "Chain")
                        Text("Wheel torque and top speed are estimates from speed/RPM and assumed gearing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 82)
        }
    }

    private func title(_ a: String, _ b: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(a).font(.largeTitle.weight(.heavy))
                Text(b).font(.caption).foregroundStyle(.cyan)
            }
            Spacer()
            ConnectionPill()
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
    }

    private func heatBar(value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value < 55 ? "Safe" : (value < 75 ? "Warm" : "Hot / Power Reduced"))
                .font(.caption.weight(.bold))
                .foregroundStyle(value < 55 ? .green : (value < 75 ? .orange : .red))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(value < 55 ? .green : (value < 75 ? .orange : .red))
                        .frame(width: geo.size.width * min(value / 100.0, 1.0))
                }
            }
            .frame(height: 10)
        }
    }
}
