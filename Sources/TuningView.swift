import SwiftUI

struct TuningView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var tuning: TuningStore
    @EnvironmentObject var settings: AppSettings

    @State private var selectedGroup: TuningGroup = .brake
    @State private var showUnlock = false
    @State private var pendingToggle: TuningParameter?
    @State private var pendingPicker: TuningParameter?
    @State private var showWriteConfirm = false

    var filtered: [TuningParameter] {
        tuning.parameters.filter { $0.group == selectedGroup }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    // Status + read/backup controls
                    GlassCard(glow: tuning.didLoadFromController) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(tuning.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button(tuning.isReading ? "Reading..." : "Read Current Settings") {
                                    ble.readCurrentSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                .disabled((!ble.isConnected && !ble.isDemoMode) || tuning.isReading)

                                Button("Backup") { tuning.saveBackup(reason: "manual") }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    // Group picker
                    Picker("Group", selection: $selectedGroup) {
                        ForEach(TuningGroup.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !settings.expertTuningUnlocked {
                        lockedCard
                    } else {
                        // Throttle curve gets a compact visual overview card
                        if selectedGroup == .throttle {
                            ThrottleCurvePreview(params: filtered)
                        }

                        ForEach(filtered) { param in
                            switch param.kind {
                            case .toggle:
                                ToggleRow(param: param, disabled: !tuning.didLoadFromController) { newVal in
                                    var edited = param; edited.pendingValue = newVal
                                    pendingToggle = edited
                                }
                            case .slider:
                                SliderRow(param: param, disabled: !tuning.didLoadFromController) { newVal in
                                    tuning.updatePending(id: param.id, value: newVal)
                                }
                            case .picker:
                                PickerRow(param: param, disabled: !tuning.didLoadFromController) { newVal in
                                    var edited = param; edited.pendingValue = newVal
                                    pendingPicker = edited
                                }
                            }
                        }

                        if !tuning.changedParameters.isEmpty {
                            Button("Write \(tuning.changedParameters.count) Changed Setting(s)") {
                                showWriteConfirm = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(!tuning.didLoadFromController || tuning.isWriting)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 82)
            }

            // ── Dialogs ────────────────────────────────────────────────────
            if showUnlock {
                StyledConfirmDialog(
                    title: "Unlock Tuning?",
                    message: "Changing controller parameters can affect performance and safety. The app backs up originals before writing. Proceed only if you understand the risks.",
                    confirmTitle: "I Understand — Unlock",
                    cancelTitle: "Cancel",
                    systemImage: "exclamationmark.triangle.fill",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        settings.expertTuningUnlocked = true
                        showUnlock = false
                    },
                    onCancel: { showUnlock = false }
                )
            }

            if let param = pendingToggle {
                let enable = (param.pendingValue ?? 0) >= 0.5
                StyledConfirmDialog(
                    title: enable ? "Enable \(param.displayName)?" : "Disable \(param.displayName)?",
                    message: "\(param.detail)\n\nRegister: \(param.internalName)  •  Addr \(param.id)",
                    confirmTitle: enable ? "Enable" : "Disable",
                    cancelTitle: "Cancel",
                    systemImage: "slider.horizontal.3",
                    destructive: false,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        tuning.updatePending(id: param.id, value: enable ? 1 : 0)
                        pendingToggle = nil
                    },
                    onCancel: { pendingToggle = nil }
                )
            }

            if let param = pendingPicker {
                let value = Int(param.pendingValue ?? 0)
                StyledConfirmDialog(
                    title: "Set \(param.displayName)?",
                    message: "\(param.detail)\n\nNew value: \(value)\nRegister: \(param.internalName)  •  Addr \(param.id)\n\nController restart may be required.",
                    confirmTitle: "Confirm",
                    cancelTitle: "Cancel",
                    systemImage: "car.fill",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        tuning.updatePending(id: param.id, value: Double(value))
                        pendingPicker = nil
                    },
                    onCancel: { pendingPicker = nil }
                )
            }

            if showWriteConfirm {
                StyledConfirmDialog(
                    title: "Write \(tuning.changedParameters.count) Setting(s)?",
                    message: "Original settings will be backed up first. Only changed parameters will be written to the controller.",
                    confirmTitle: "Backup & Write",
                    cancelTitle: "Cancel",
                    systemImage: "square.and.arrow.down.on.square.fill",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        ble.writeChangedSettings(tuning.changedParameters)
                        showWriteConfirm = false
                    },
                    onCancel: { showWriteConfirm = false }
                )
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Tuning").font(.largeTitle.weight(.heavy))
                Text("Read first. Backup before write.").font(.caption).foregroundStyle(.cyan)
            }
            Spacer()
            ConnectionPill()
        }
    }

    private var lockedCard: some View {
        GlassCard(glow: true) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text("Tuning Locked").font(.title2.weight(.bold))
                Text("Press unlock to access controller parameters.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Unlock Tuning") {
                    SoundManager.shared.playWarningSound(enabled: settings.startupSound)
                    showUnlock = true
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Throttle curve visual preview

struct ThrottleCurvePreview: View {
    let params: [TuningParameter]

    var points: [Double] {
        params.filter { $0.internalName.hasPrefix("PAccCurveSet") }
            .sorted { $0.id < $1.id }
            .map { $0.pendingValue ?? $0.currentValue ?? 0 }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Throttle Curve Preview").font(.headline)
                Text("Horizontal = throttle position (0→100%)  •  Vertical = torque output (0→100%)")
                    .font(.caption2).foregroundStyle(.secondary)

                GeometryReader { geo in
                    let pts = points
                    guard pts.count > 1 else { return AnyView(EmptyView()) }
                    return AnyView(
                        ZStack {
                            // Grid lines
                            ForEach([0.25, 0.5, 0.75], id: \.self) { frac in
                                Path { p in
                                    let y = geo.size.height * (1 - frac)
                                    p.move(to: CGPoint(x: 0, y: y))
                                    p.addLine(to: CGPoint(x: geo.size.width, y: y))
                                }
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            }
                            // Curve
                            Path { path in
                                for (i, v) in pts.enumerated() {
                                    let x = CGFloat(i) / CGFloat(pts.count - 1) * geo.size.width
                                    let y = geo.size.height * CGFloat(1 - v)
                                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                                }
                            }
                            .stroke(Color.cyan, lineWidth: 2)
                        }
                    )
                }
                .frame(height: 80)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Row kinds

struct ToggleRow: View {
    let param: TuningParameter
    let disabled: Bool
    let onChange: (Double) -> Void

    var body: some View {
        GlassCard(glow: param.hasChange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(param.displayName).font(.headline)
                        Text("\(param.internalName)  •  Addr \(param.id)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if param.isRisky {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(param.detail).font(.caption).foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { (param.pendingValue ?? param.currentValue ?? 0) >= 0.5 },
                    set: { onChange($0 ? 1 : 0) }
                )) {
                    Text((param.pendingValue ?? param.currentValue ?? 0) >= 0.5 ? "Enabled" : "Disabled")
                        .fontWeight(.semibold)
                }
                .tint(.cyan)
                .disabled(disabled || !param.loaded)

                notLoadedHint(param)
                changeHint(param)
            }
        }
    }
}

struct SliderRow: View {
    let param: TuningParameter
    let disabled: Bool
    let onChange: (Double) -> Void

    private var value: Double { param.pendingValue ?? param.currentValue ?? param.min }

    var body: some View {
        GlassCard(glow: param.hasChange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(param.displayName).font(.headline)
                        Text("\(param.internalName)  •  Addr \(param.id)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2f", value))
                        .font(.title3.weight(.bold)).foregroundStyle(.cyan)
                        .monospacedDigit()
                }
                Text(param.detail).font(.caption).foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { value },
                        set: { onChange(Double(Int(($0 / param.step).rounded())) * param.step) }
                    ),
                    in: param.min...param.max
                )
                .tint(.cyan)
                .disabled(disabled || !param.loaded)

                notLoadedHint(param)
                changeHint(param)
            }
        }
    }
}

struct PickerRow: View {
    let param: TuningParameter
    let disabled: Bool
    let onChange: (Double) -> Void

    private var selected: Int { Int((param.pendingValue ?? param.currentValue ?? param.min).rounded()) }
    private var options: [Int] { Array(Int(param.min)...Int(param.max)) }

    private func label(for value: Int) -> String {
        switch param.internalName {
        case "PMotorType":
            return value == 0 ? "0 — Standard" : "1 — High-power"
        default:
            return "\(value)"
        }
    }

    var body: some View {
        GlassCard(glow: param.hasChange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(param.displayName).font(.headline)
                        Text("\(param.internalName)  •  Addr \(param.id)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if param.isRisky {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(param.detail).font(.caption).foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { selected },
                    set: { onChange(Double($0)) }
                )) {
                    ForEach(options, id: \.self) { opt in
                        Text(label(for: opt)).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(disabled || !param.loaded)

                notLoadedHint(param)
                changeHint(param)
            }
        }
    }
}

// MARK: - Shared hint helpers

@ViewBuilder
private func notLoadedHint(_ param: TuningParameter) -> some View {
    if !param.loaded {
        Text("Not loaded yet — press Read Current Settings first.")
            .font(.caption2).foregroundStyle(.orange)
    }
}

@ViewBuilder
private func changeHint(_ param: TuningParameter) -> some View {
    if param.hasChange {
        Text("Changed: \(String(format: "%.4f", param.currentValue ?? 0)) → \(String(format: "%.4f", param.pendingValue ?? 0))")
            .font(.caption2).foregroundStyle(.cyan)
    }
}
