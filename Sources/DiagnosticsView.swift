import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var tuning: TuningStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Diagnostics").font(.largeTitle.weight(.heavy))
                        Text("Bluetooth, packets and app state").font(.caption).foregroundStyle(.cyan)
                    }
                    Spacer()
                    ConnectionPill()
                }

                GlassCard(glow: true) {
                    VStack(spacing: 12) {
                        row("Controller", ble.telemetry.controllerName)
                        row("Product", ble.telemetry.productModel)
                        row("Connected name", ble.connectedName ?? "None")
                        row("Connection", ble.connectionStatus)
                        row("Packets", "\(ble.telemetry.packetCount)")
                        row("Update interval", settings.updateInterval.label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GlassCard {
                    VStack(spacing: 12) {
                        row("Settings loaded", tuning.didLoadFromController ? "Yes" : "No")
                        row("Tuning unlocked", settings.expertTuningUnlocked ? "Yes" : "No")
                        row("Demo mode", ble.isDemoMode ? "On" : "Off")
                        row("Saved devices", "\(ble.savedDevices.count)")
                        row("Developer", settings.developerUnlocked ? "Unlocked" : "Locked")
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Diagnostic History").font(.headline)
                        if ble.diagnosticEvents.isEmpty {
                            Text("No events yet").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(ble.diagnosticEvents.prefix(12)) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(event.title).font(.caption.weight(.bold))
                                        Spacer()
                                        Text(event.severity.uppercased()).font(.caption2).foregroundStyle(event.severity == "error" ? .red : .orange)
                                    }
                                    Text(event.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Divider().opacity(0.2)
                            }
                        }
                    }
                }

                if settings.showRawPackets {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Latest Raw Packet").font(.headline)
                            Text(ble.telemetry.rawHex.isEmpty ? "No packet yet" : ble.telemetry.rawHex)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            ForEach(ble.packetLog.prefix(14), id: \.self) { packet in
                                Text(packet)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 82)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
    }
}
