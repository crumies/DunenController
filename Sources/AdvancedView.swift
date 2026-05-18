import SwiftUI

struct AdvancedView: View {
    let telemetry: Telemetry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Advanced")
                            .font(.largeTitle.weight(.heavy))
                        Text("Read-only controller data")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    ConnectionPill()
                }

                GlassCard(glow: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Input Sensors")
                            .font(.headline)

                        statusRow("Front Brake", active: telemetry.frontBrakePressed)
                        statusRow("Rear Brake", active: telemetry.rearBrakePressed)
                        statusRow("Park Brake", active: telemetry.parkBrakePressed, color: .orange)
                        statusRow("Kickstand / Stand", active: telemetry.standSensorActive, color: .orange)
                        statusRow("Reverse", active: telemetry.reverseActive, color: .purple)
                        statusRow("Regen Active", active: telemetry.regenActive, color: .cyan)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Motor / Power")
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
                        metricLine("Mode", telemetry.sportMode ? "Sport" : (telemetry.ecoMode ? "Eco" : "Normal"))
                        metricLine("Protection", telemetry.protectionState)
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

                        Text("No iPhone GPS or motion sensors. These only update if DUNEN packets expose them.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 112)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
    }

    private func statusRow(_ name: String, active: Bool, color: Color = .green) -> some View {
        HStack {
            Image(systemName: active ? "circle.fill" : "circle")
                .foregroundStyle(active ? color : .white.opacity(0.3))
                .shadow(color: active ? color.opacity(0.8) : .clear, radius: 8)
            Text(name)
            Spacer()
            Text(active ? "ON" : "OFF")
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? color : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((active ? color : .white).opacity(active ? 0.14 : 0.06))
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f°", angle)).font(.title.weight(.bold))
            ZStack(alignment: .center) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 2)
                Rectangle().fill(.cyan).frame(width: 80, height: 3).rotationEffect(.degrees(angle))
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
