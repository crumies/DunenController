import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var tuning: TuningStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var appLog = AppLogManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RegisterProbeCard()
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
                        row("BLE Service", "FFE0")
                        row("Notify/Read", "FFE1")
                        row("Write", "FFF2")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GlassCard {
                    VStack(spacing: 12) {
                        row("Settings loaded", tuning.didLoadFromController ? "Yes" : "No")
                        row("Tuning unlocked", settings.expertTuningUnlocked ? "Yes" : "No")
                        if ble.isDemoMode {
                            row("Demo mode", "On")
                        }
                        row("Saved devices", "\(ble.savedDevices.count)")
                        row("Brake", ble.telemetry.brakeActive ? "Active" : "Off")
                        row("Gear", "\(ble.telemetry.gearInputRaw)")
                        row("BMS SOC", String(format: "%.0f %%", ble.telemetry.bmsSoc))
                        row("Confirmed toggles", "99 / 211 / 212")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Export Debug Logs").font(.headline)
                                Text("Saves BLE TX/RX, parser output, connection events and errors.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            ShareLink(item: appLog.logURL) {
                                Label("Share TXT", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)

                            ShareLink(item: appLog.jsonURL) {
                                Label("Share JSONL", systemImage: "doc.text")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(role: .destructive) {
                            appLog.clear()
                        } label: {
                            Label("Clear Log", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        if appLog.latestLines.isEmpty {
                            Text("No app logs yet. Connect to the bike, wait 15 seconds, then share TXT.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appLog.latestLines.prefix(10), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Diagnostic History").font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity)
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

struct RegisterProbeCard: View {
    @EnvironmentObject var ble: DunenBLEManager

    // Known useful register blocks with descriptions
    private let knownBlocks: [(label: String, start: Int, count: Int)] = [
        ("Live dashboard (0x0400, 24 regs)", 0x0400, 24),
        ("Speed OVechSpd (362, 12 params)", 362, 24),
        ("Voltage/5V/15V (338, 12 params)",  338, 24),
        ("Current IADin9 (266, 12 params)",  266, 24),
        ("Torque OTorq (314, 12 params)",    314, 24),
        ("Fault/warn (410, 12 params)",       410, 24),
    ]

    @State private var startText = "362"
    @State private var countText = "24"

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Register Probe").font(.headline)
                Text("Read any register block and see raw 32-bit values. Use this to find what the controller actually sends.")
                    .font(.caption).foregroundStyle(.secondary)

                // Quick-pick known blocks
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(knownBlocks, id: \.start) { block in
                            Button(block.label) {
                                startText = "\(block.start)"
                                countText = "\(block.count)"
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.cyan.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start address").font(.caption2).foregroundStyle(.secondary)
                        TextField("e.g. 362", text: $startText)
                            .keyboardType(.numberPad)
                            .padding(8)
                            .background(.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Count (16-bit)").font(.caption2).foregroundStyle(.secondary)
                        TextField("e.g. 24", text: $countText)
                            .keyboardType(.numberPad)
                            .padding(8)
                            .background(.white.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button {
                        let start = Int(startText) ?? 362
                        let count = Int(countText) ?? 24
                        ble.probeRegister(start: start, count: count)
                    } label: {
                        if ble.probeInFlight {
                            ProgressView().tint(.cyan)
                        } else {
                            Text("Send").bold()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(ble.probeInFlight || !ble.isConnected)
                }

                if !ble.probeResult.isEmpty {
                    ScrollView {
                        Text(ble.probeResult)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 280)
                    .padding(10)
                    .background(.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

