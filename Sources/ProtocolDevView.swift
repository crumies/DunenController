import SwiftUI

// MARK: - Protocol Development View
// Reads raw Modbus register blocks from the DUNEN controller and displays them
// exactly as described in the PDF protocol document:
//   • Function 0x03 read request: [01 03 addrH addrL 00 count CRClo CRChi]
//   • Response:                   [01 03 byteCount data... CRClo CRChi]
//   • Parameter address = (row - 2) * 2
//   • U32 value: two 16-bit registers big-endian
//   • IQ16 value: U32 / 65536
//
// Table 2 (live debug variables) starts at address 0x03E8 (decimal 1000).

struct ProtocolDevView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings

    // Preset address blocks from the PDF
    private let presets: [(name: String, start: Int, count: Int)] = [
        ("Table 1 — Row 2–13 (params 0–23)",  0,       24),
        ("Table 1 — Row 26–37 (params 24–47)", 24,      24),
        ("Table 1 — Row 50–61 (params 48–71)", 48,      24),
        ("Table 2 — Live block (0x03E8/1000)", 0x03E8,  18),
        ("Table 2 — Live output (0x0400/1024)",0x0400,  24),
        ("Table 2 — Fault/status (0x0418/1048)",0x0418, 2),
        ("Output — Torque/Mode (0x0122)",       0x0122,  24),
        ("Output — Speed/Temps (0x013A)",       0x013A,  24),
        ("Output — Faults (0x0152)",            0x0152,  24),
    ]

    @State private var selectedPreset = 0
    @State private var customAddressText = ""
    @State private var customCountText = "24"
    @State private var useCustom = false
    @State private var showWriteSheet = false

    private var resolvedStart: Int {
        if useCustom {
            let s = customAddressText.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("0x") || s.hasPrefix("0X") {
                return Int(s.dropFirst(2), radix: 16) ?? 0
            }
            return Int(s) ?? 0
        }
        return presets[selectedPreset].start
    }

    private var resolvedCount: Int {
        if useCustom {
            return Int(customCountText.trimmingCharacters(in: .whitespaces)) ?? 24
        }
        return presets[selectedPreset].count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Protocol Dev").font(.largeTitle.weight(.heavy))
                        Text("Raw Modbus register reader — PDF protocol mode")
                            .font(.caption).foregroundStyle(.cyan)
                    }
                    Spacer()
                    ConnectionPill()
                }

                // Mode notice
                if settings.controllerAppMode == .standard {
                    GlassCard {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                            Text("Switch to Development mode in Settings to use this tab normally. Standard mode keeps the dashboard clean.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Block selector
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "tablecells").foregroundStyle(.cyan)
                            Text("Register Block").font(.headline)
                        }

                        Toggle("Custom address", isOn: $useCustom.animation()).tint(.cyan)

                        if useCustom {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Start address (hex or dec)").font(.caption).foregroundStyle(.secondary)
                                    TextField("e.g. 0x0400 or 1024", text: $customAddressText)
                                        .textFieldStyle(.roundedBorder)
                                        .keyboardType(.default)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Count (16-bit regs)").font(.caption).foregroundStyle(.secondary)
                                    TextField("24", text: $customCountText)
                                        .textFieldStyle(.roundedBorder)
                                        .keyboardType(.numberPad)
                                        .frame(width: 70)
                                }
                            }
                        } else {
                            Picker("Preset block", selection: $selectedPreset) {
                                ForEach(0..<presets.count, id: \.self) { i in
                                    Text(presets[i].name).tag(i)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.cyan)
                        }

                        HStack(spacing: 10) {
                            Button {
                                ble.requestRawBlock(start: resolvedStart, count: resolvedCount)
                            } label: {
                                Label("Read Block", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(!ble.isConnected && !ble.isDemoMode)

                            Button {
                                showWriteSheet = true
                            } label: {
                                Label("Write", systemImage: "pencil.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(!ble.isConnected)
                        }

                        Text(ble.protocolDevStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                }

                // Protocol frame preview (TX frame)
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.cyan)
                            Text("TX Frame Preview").font(.headline)
                        }
                        let frame = DunenProtocol.modbusReadFrame(start: resolvedStart, count: resolvedCount)
                        Text(frame.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Modbus read (FC=03): slave=0x01  start=0x\(String(resolvedStart, radix: 16, uppercase: true))  count=\(resolvedCount)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Per PDF: addr = (row − 2) × 2 | U32 = hi×65536+lo | IQ16 = U32 ÷ 65536")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                // Register table
                if ble.protocolDevRegisters.isEmpty {
                    GlassCard {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").foregroundStyle(.secondary).font(.largeTitle)
                            Text("No registers loaded yet")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Tap \"Read Block\" while connected to the controller.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                } else {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Image(systemName: "list.number").foregroundStyle(.cyan)
                                Text("Register Data").font(.headline)
                                Spacer()
                                Text("\(ble.protocolDevRegisters.count) params").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)

                            // Column header
                            HStack {
                                Text("Addr").font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                                Text("Row").font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                                Text("U32").font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                                Text("IQ16").font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.3)

                            ForEach(ble.protocolDevRegisters) { reg in
                                registerRow(reg)
                                Divider().opacity(0.15)
                            }
                        }
                    }
                }

                // Live raw packet for cross-reference
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(.cyan)
                            Text("Last RX Packet").font(.headline)
                        }
                        Text(ble.telemetry.rawHex.isEmpty ? "No packet yet" : ble.telemetry.rawHex)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                    }
                }

                // PDF protocol reminder
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.cyan)
                            Text("Protocol Notes").font(.headline)
                        }
                        Group {
                            noteRow("Read cmd", "01 03 addrH addrL 00 count CRClo CRChi")
                            noteRow("Write cmd", "01 10 addrH addrL 00 count 00 d1H d1L... CRClo CRChi")
                            noteRow("Response",  "01 03 byteCount data... CRClo CRChi")
                            noteRow("Table 1 addr", "(row − 2) × 2")
                            noteRow("Table 2 base", "0x03E8 (decimal 1000)")
                            noteRow("U32",  "32-bit integer, big-endian, 2 registers")
                            noteRow("IQ16", "U32 ÷ 65536 (signed fixed-point)")
                            noteRow("Save", "Write 0 to address 0x02E1 (row 273)")
                            noteRow("BLE service", "FFE0 | Notify: FFE1 | Write: FFF2")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 82)
        }
        .sheet(isPresented: $showWriteSheet) {
            WriteParameterSheet(isPresented: $showWriteSheet)
                .environmentObject(ble)
        }
    }

    private func registerRow(_ reg: ProtocolRegisterWord) -> some View {
        let tableRow = reg.address / 2 + 2  // inverse of (row-2)*2
        return HStack {
            Text("0x\(String(format: "%04X", reg.address))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan).frame(width: 54, alignment: .leading)
            Text("\(tableRow)").font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            if let u32 = reg.u32Value {
                Text("\(u32)").font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("\(reg.word)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let iq = reg.iq16Value {
                Text(String(format: "%.4f", iq)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange).frame(width: 80, alignment: .trailing)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func noteRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Write Parameter Sheet

struct WriteParameterSheet: View {
    @EnvironmentObject var ble: DunenBLEManager
    @Binding var isPresented: Bool
    @State private var addressText = ""
    @State private var valueText = ""
    @State private var isIQ16 = false
    @State private var confirmShown = false

    private var resolvedAddress: Int {
        let s = addressText.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return Int(s.dropFirst(2), radix: 16) ?? 0 }
        return Int(s) ?? 0
    }

    private var resolvedRaw: UInt32 {
        let v = Double(valueText.trimmingCharacters(in: .whitespaces)) ?? 0
        if isIQ16 {
            // IQ16: multiply by 65536 to convert display value to raw
            return UInt32(bitPattern: Int32(v * 65536.0))
        }
        return UInt32(bitPattern: Int32(v.rounded()))
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Write address") {
                    TextField("Address (hex 0x… or decimal)", text: $addressText).keyboardType(.default)
                    Text("Row = address ÷ 2 + 2").font(.caption).foregroundStyle(.secondary)
                }
                Section("Value") {
                    TextField("Value", text: $valueText).keyboardType(.decimalPad)
                    Toggle("IQ16 format (value × 65536)", isOn: $isIQ16).tint(.orange)
                    if isIQ16 {
                        let disp = Double(valueText) ?? 0
                        Text("Raw = \(Int32(bitPattern: UInt32(bitPattern: Int32(disp * 65536))))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Write to controller") {
                        confirmShown = true
                    }
                    .foregroundStyle(.orange)
                    .disabled(addressText.isEmpty || valueText.isEmpty)
                }
                Section("TX Frame Preview") {
                    let frame = DunenProtocol.modbusWriteU32FramePublic(start: resolvedAddress, raw: resolvedRaw)
                    Text(frame.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Write Parameter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .alert("Write to controller?", isPresented: $confirmShown) {
                Button("Write", role: .destructive) {
                    ble.requestWrite(start: resolvedAddress, raw: resolvedRaw)
                    isPresented = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will send a Modbus write to address 0x\(String(format: "%04X", resolvedAddress)). Make sure you know what this register does.")
            }
        }
    }
}
