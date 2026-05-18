import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var ble: DunenBLEManager
    let telemetry: Telemetry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Advanced")
                            .font(.largeTitle.weight(.heavy))
                        Text("BLE controller telemetry")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    ConnectionPill()
                }

                GlassCard(glow: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Brake Sensors")
                            .font(.headline)

                        brakeRow("Front Brake", pressed: telemetry.frontBrakePressed)
                        brakeRow("Rear Brake", pressed: telemetry.rearBrakePressed)
                        brakeRow("Regen Active", pressed: telemetry.regenActive, color: .cyan)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Motor")
                            .font(.headline)

                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading) {
                                Text("RPM")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(telemetry.rpm)")
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                            }
                            Spacer()
                            MiniGraph(value: Double(telemetry.rpm) / 9000)
                                .frame(width: 140, height: 70)
                        }

                        divider
                        metricLine("Throttle", String(format: "%.0f %%", telemetry.throttlePercent))
                        metricLine("Controller Current", String(format: "%.1f A", telemetry.currentA))
                        metricLine("Phase Current", String(format: "%.1f A", telemetry.phaseCurrentA))
                        metricLine("Fault", telemetry.faultText)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tilt / Angle from BLE")
                            .font(.headline)

                        HStack(spacing: 12) {
                            tiltCard("Front / Back", telemetry.tiltFrontBack)
                            tiltCard("Left / Right", telemetry.tiltLeftRight)
                        }

                        Text("Note: this does not use iPhone motion sensors. Values depend on DUNEN packets exposing tilt/IMU data.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Raw Packet")
                                .font(.headline)
                            Spacer()
                            Text("\(telemetry.packetCount) packets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(telemetry.rawHex.isEmpty ? "No packet yet" : telemetry.rawHex)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 110)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
    }

    private func brakeRow(_ name: String, pressed: Bool, color: Color = .green) -> some View {
        HStack {
            Image(systemName: pressed ? "circle.fill" : "circle")
                .foregroundStyle(pressed ? color : .white.opacity(0.3))
                .shadow(color: pressed ? color.opacity(0.8) : .clear, radius: 8)
            Text(name)
            Spacer()
            Text(pressed ? "PRESSED" : "OFF")
                .font(.caption.weight(.bold))
                .foregroundStyle(pressed ? color : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((pressed ? color : .white).opacity(pressed ? 0.14 : 0.06))
                .clipShape(Capsule())
        }
    }

    private func metricLine(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
    }

    private func tiltCard(_ title: String, _ angle: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f°", angle))
                .font(.title.weight(.bold))
            ZStack(alignment: .center) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 2)
                Rectangle().fill(.cyan).frame(width: 80, height: 3)
                    .rotationEffect(.degrees(angle))
            }
            .frame(height: 42)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct MiniGraph: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: CGPoint(x: 0, y: h * 0.75))
                for i in 0...18 {
                    let x = w * CGFloat(i) / 18
                    let wave = sin(Double(i) * 0.85) * 0.14
                    let y = h * (0.75 - CGFloat(min(max(value, 0), 1)) * 0.55 - CGFloat(wave))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: .cyan.opacity(0.5), radius: 8)
        }
    }
}
