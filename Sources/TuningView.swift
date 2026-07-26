import SwiftUI

// MARK: - Main Tuning View

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

                    // ── Disclaimer ─────────────────────────────────────────────
                    disclaimerBanner

                    // ── Vehicle Model — always visible, no lock required ────────
                    VehicleModelCard()

                    // ── Read / Backup controls ─────────────────────────────────
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

                    // ── Group picker ───────────────────────────────────────────
                    Picker("Group", selection: $selectedGroup) {
                        ForEach(TuningGroup.allCases, id: \.self) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !settings.expertTuningUnlocked {
                        lockedCard
                    } else {
                        // Brake tab: show hero brake cutoff card first
                        if selectedGroup == .brake {
                            BrakeCutoffHeroCard(
                                param: tuning.parameters.first { $0.internalName == "PBrkCmdOffEn" },
                                disabled: !tuning.didLoadFromController
                            ) { newVal in
                                if let p = tuning.parameters.first(where: { $0.internalName == "PBrkCmdOffEn" }) {
                                    var edited = p; edited.pendingValue = newVal
                                    pendingToggle = edited
                                }
                            }
                        }

                        // Throttle tab: show preset picker + live SVG preview first
                        if selectedGroup == .throttle {
                            ThrottlePresetCard(disabled: !tuning.didLoadFromController)
                            ThrottleCurvePreview(params: filtered)
                        }

                        // Parameter rows (skip PBrkCmdOffEn in Brake — shown in hero)
                        ForEach(filtered.filter { p in
                            !(selectedGroup == .brake && p.internalName == "PBrkCmdOffEn")
                        }) { param in
                            switch param.kind {
                            case .toggle:
                                ToggleRow(param: param, disabled: !tuning.didLoadFromController) { newVal in
                                    var edited = param; edited.pendingValue = newVal
                                    pendingToggle = edited
                                }
                            case .slider:
                                SliderRow(param: param, disabled: !tuning.didLoadFromController) { newVal in
                                    tuning.updatePendingMonotone(id: param.id, value: newVal)
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

            // ── Dialogs ──────────────────────────────────────────────────────

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

    private var disclaimerBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            Text("We are not responsible for actions which may happen after settings are changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

// MARK: - Vehicle Model Card (always visible, no lock, visual only)

private struct VehicleModelCard: View {
    @EnvironmentObject var settings: AppSettings

    private let models: [(model: VehicleModel, icon: String, kw: String, detail: String)] = [
        (.standard,  "bolt.circle",      "8 kW",  "8kW / 72V — standard configuration"),
        (.highPower, "bolt.circle.fill", "10 kW", "10kW / 72V — high power configuration"),
    ]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "car.2.fill")
                        .foregroundStyle(.cyan)
                    Text("Vehicle Model  (车型选择)")
                        .font(.headline.weight(.bold))
                    Spacer()
                    Text("Visual only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ForEach(models, id: \.model) { item in
                        let selected = settings.selectedVehicleModel == item.model
                        Button {
                            // Visual only — just save to app settings, never writes to controller
                            settings.selectedVehicleModel = item.model
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: item.icon)
                                    .font(.title)
                                    .foregroundStyle(selected ? .cyan : .secondary)
                                Text(item.model.rawValue)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                Text(item.kw)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(selected ? .cyan : .secondary)
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(selected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selected ? Color.cyan.opacity(0.7) : Color.white.opacity(0.12), lineWidth: selected ? 1.5 : 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
                    }
                }

                Text("This selection is for display purposes only and does not change any controller parameters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Brake Cutoff Hero Card

private struct BrakeCutoffHeroCard: View {
    let param: TuningParameter?
    let disabled: Bool
    let onChange: (Double) -> Void

    private var isEnabled: Bool {
        (param?.pendingValue ?? param?.currentValue ?? 0) >= 0.5
    }

    var body: some View {
        GlassCard(glow: isEnabled) {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "brake.signal")
                        .font(.title2)
                        .foregroundStyle(isEnabled ? .cyan : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brake Cutoff  (刹车断电)")
                            .font(.title3.weight(.bold))
                        Text("Most commonly used setting")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Big status pill
                    Text(isEnabled ? "ON" : "OFF")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(isEnabled ? .black : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(isEnabled ? Color.cyan : Color.white.opacity(0.10))
                        .clipShape(Capsule())
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isEnabled)
                }

                Text("When ON, squeezing the brake lever immediately cuts motor power — the safest and most common configuration. When OFF, the motor continues running through braking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    // OFF button
                    Button {
                        guard !disabled, let _ = param else { return }
                        onChange(0)
                    } label: {
                        Text("Disable")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(!isEnabled ? Color.white.opacity(0.18) : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.22), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(!isEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled || param == nil)

                    // ON button
                    Button {
                        guard !disabled, let _ = param else { return }
                        onChange(1)
                    } label: {
                        Text("Enable")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isEnabled ? Color.cyan.opacity(0.85) : Color.cyan.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(isEnabled ? .black : .cyan)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled || param == nil)
                }

                if param == nil || !(param?.loaded ?? false) {
                    Text("Press \"Read Current Settings\" to load the current controller value.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let p = param, let c = p.currentValue, let pv = p.pendingValue, abs(c - pv) > 0.0001 {
                    Text("Pending change: \(c >= 0.5 ? "ON" : "OFF") → \(pv >= 0.5 ? "ON" : "OFF")  •  Will write on next Write action.")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

// MARK: - Throttle Preset Card

private struct ThrottlePresetCard: View {
    @EnvironmentObject var tuning: TuningStore
    let disabled: Bool

    enum ThrottlePreset: String, CaseIterable, Identifiable {
        case eco    = "Eco"
        case linear = "Linear"
        case sport  = "Sport"
        case custom = "Custom"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .eco: return "leaf.fill"
            case .linear: return "equal"
            case .sport: return "flame.fill"
            case .custom: return "slider.horizontal.3"
            }
        }

        var color: Color {
            switch self {
            case .eco: return .green
            case .linear: return .cyan
            case .sport: return .orange
            case .custom: return .purple
            }
        }

        var description: String {
            switch self {
            case .eco:    return "Gentle / progressive — starts soft, builds gradually. Good for city."
            case .linear: return "Straight 1:1 — torque directly follows throttle position."
            case .sport:  return "Aggressive — jumps to 60% torque at half throttle. Max response."
            case .custom: return "Your own curve — adjust each point manually below."
            }
        }

        // 15 normalised torque fractions (0.0–1.0)
        var points: [Double]? {
            switch self {
            case .eco:
                return [0.03, 0.06, 0.10, 0.14, 0.19, 0.25, 0.32, 0.40, 0.49, 0.58, 0.68, 0.77, 0.86, 0.93, 1.00]
            case .linear:
                return stride(from: 1, through: 15, by: 1).map { Double($0) / 15.0 }
            case .sport:
                return [0.12, 0.22, 0.33, 0.44, 0.55, 0.63, 0.70, 0.77, 0.83, 0.88, 0.92, 0.95, 0.97, 0.99, 1.00]
            case .custom:
                return nil
            }
        }
    }

    // Current active preset (detected from live points, else .custom)
    private var activePreset: ThrottlePreset {
        let current = currentPoints
        for preset in [ThrottlePreset.eco, .linear, .sport] {
            guard let pts = preset.points else { continue }
            if zip(current, pts).allSatisfy({ abs($0.0 - $0.1) < 0.005 }) { return preset }
        }
        return .custom
    }

    private var currentPoints: [Double] {
        tuning.parameters
            .filter { $0.group == .throttle && $0.kind == .slider }
            .sorted { $0.id < $1.id }
            .map { $0.pendingValue ?? $0.currentValue ?? 0 }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(.cyan)
                    Text("Throttle Preset  (油门预设)")
                        .font(.headline.weight(.bold))
                }

                // Preset selector tiles
                HStack(spacing: 8) {
                    ForEach(ThrottlePreset.allCases) { preset in
                        let selected = activePreset == preset
                        Button {
                            guard !disabled, let pts = preset.points else { return }
                            applyPreset(pts)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: preset.icon)
                                    .font(.title3)
                                    .foregroundStyle(selected ? preset.color : .secondary)
                                Text(preset.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(selected ? preset.color.opacity(0.15) : Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                                selected ? preset.color.opacity(0.7) : Color.white.opacity(0.10), lineWidth: selected ? 1.5 : 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled || preset == .custom)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
                    }
                }

                Text(activePreset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyPreset(_ pts: [Double]) {
        // IDs are 532, 534, 536 ... 560 (step 2, 15 points)
        let baseID = 532
        for (i, val) in pts.enumerated() {
            tuning.updatePending(id: baseID + i * 2, value: val)
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
