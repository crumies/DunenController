import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    let telemetry: Telemetry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Diagnostics")
                            .font(.largeTitle.weight(.heavy))
                        Text("No tuning, read-only monitor")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                    ConnectionPill()
                }

                GlassCard(glow: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Controller Identity")
                            .font(.headline)

                        row("Controller", telemetry.controllerModel)
                        row("Product model", telemetry.productModel)
                        row("BLE service", telemetry.bleService)
                        row("Characteristic", telemetry.bleCharacteristic)
                        row("Firmware/App style", telemetry.firmwareText)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Protection / Faults")
                            .font(.headline)

                        row("Protection state", telemetry.protectionState)
                        row("Fault", telemetry.faultText)
                        row("Voltage", String(format: "%.1f V", telemetry.voltage))
                        row("Controller temp", String(format: "%.0f °C", telemetry.controllerTemp))
                        row("Motor temp", String(format: "%.0f °C", telemetry.motorTemp))
                    }
                }

                if settings.showRawPackets {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Raw BLE Packet")
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

                            if !ble.packetLog.isEmpty {
                                Text("Recent")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)

                                ForEach(ble.packetLog.prefix(10), id: \.self) { packet in
                                    Text(packet)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 112)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
    }
}
