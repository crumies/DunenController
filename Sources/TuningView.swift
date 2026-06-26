import SwiftUI

struct TuningView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var tuning: TuningStore
    @EnvironmentObject var settings: AppSettings

    @State private var selectedGroup: TuningGroup = .common
    @State private var showUnlock = false
    @State private var pendingToggle: TuningParameter?
    @State private var showWriteConfirm = false

    var filtered: [TuningParameter] {
        tuning.parameters.filter { $0.group == selectedGroup }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

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

                                Button("Backup") {
                                    tuning.saveBackup(reason: "manual")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Picker("Group", selection: $selectedGroup) {
                        ForEach(TuningGroup.allCases, id: \.self) { group in
                            Text(group.rawValue).tag(group)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !settings.expertTuningUnlocked {
                        lockedCard
                    } else {
                        ForEach(filtered) { param in
                            ParameterRow(param: param, disabled: !tuning.didLoadFromController) { newValue in
                                var edited = param
                                edited.pendingValue = newValue
                                pendingToggle = edited
                            }
                        }

                        if !tuning.changedParameters.isEmpty {
                            Button("Write \(tuning.changedParameters.count) Changed Setting(s)") {
                                showWriteConfirm = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(!tuning.didLoadFromController || tuning.isWriting)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 82)
            }

            if showUnlock {
                StyledConfirmDialog(
                    title: "Unlock tuning?",
                    message: "Changing controller parameters is your own responsibility. The app reads settings first, backs up originals, and asks before writing.",
                    confirmTitle: "I Understand",
                    cancelTitle: "Cancel",
                    systemImage: "exclamationmark.triangle.fill",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        settings.expertTuningUnlocked = true
                        showUnlock = false
                    },
                    onCancel: {
                        showUnlock = false
                    }
                )
            }

            if let param = pendingToggle {
                let enable = (param.pendingValue ?? 0) >= 0.5
                StyledConfirmDialog(
                    title: "Are you sure?",
                    message: "Do you want to \(enable ? "enable" : "disable") \(param.displayName)?\n\nBackend: \(param.internalName)\nID: \(param.id)",
                    confirmTitle: enable ? "Enable" : "Disable",
                    cancelTitle: "Cancel",
                    systemImage: "slider.horizontal.3",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        tuning.updatePending(id: param.id, value: enable ? 1 : 0)
                        pendingToggle = nil
                    },
                    onCancel: {
                        pendingToggle = nil
                    }
                )
            }

            if showWriteConfirm {
                StyledConfirmDialog(
                    title: "Write changed settings?",
                    message: "Original settings will be backed up first. Only changed parameters will be written.",
                    confirmTitle: "Backup & Write",
                    cancelTitle: "Cancel",
                    systemImage: "square.and.arrow.down.on.square.fill",
                    destructive: true,
                    onConfirm: {
                        SoundManager.shared.playConfirmSound(enabled: settings.startupSound)
                        ble.writeChangedSettings(tuning.changedParameters)
                        showWriteConfirm = false
                    },
                    onCancel: {
                        showWriteConfirm = false
                    }
                )
            }
        }
    }

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
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Tuning Locked")
                    .font(.title2.weight(.bold))
                Text("Press unlock to access safer toggle controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Unlock Tuning") {
                    SoundManager.shared.playWarningSound(enabled: settings.startupSound)
                    showUnlock = true
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct ParameterRow: View {
    let param: TuningParameter
    let disabled: Bool
    let onChange: (Double) -> Void

    var body: some View {
        GlassCard(glow: param.hasChange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(param.displayName).font(.headline)
                        Text("\(param.internalName)  •  ID \(param.id)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(param.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: Binding(
                    get: { (param.pendingValue ?? param.currentValue ?? 0) >= 0.5 },
                    set: { onChange($0 ? 1 : 0) }
                )) {
                    Text(((param.pendingValue ?? param.currentValue ?? 0) >= 0.5) ? "Enabled" : "Disabled")
                        .fontWeight(.semibold)
                }
                .tint(.cyan)
                .disabled(disabled || !param.loaded)

                if !param.loaded {
                    Text("Not loaded yet — press Read Current Settings first.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if param.hasChange {
                    Text("Changed: original \(String(format: "%.0f", param.currentValue ?? 0)) → new \(String(format: "%.0f", param.pendingValue ?? 0))")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}
