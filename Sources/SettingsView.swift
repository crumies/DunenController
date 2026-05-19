import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: DunenBLEManager

    @State private var devTapCount = 0
    @State private var toast: AppToast?
    @State private var showDeveloperOptions = false
    @State private var showTuningWarning = false
    @State private var requestedTuningState = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Settings").font(.largeTitle.weight(.heavy))
                            Text("Aptum Dashboard").font(.caption).foregroundStyle(.cyan)
                        }
                        Spacer()
                    }

                    modernSection("Display", system: "paintbrush.fill") {
                        Picker("Appearance", selection: Binding(get: { settings.appearance }, set: { settings.appearance = $0 })) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Speed", selection: Binding(get: { settings.speedUnit }, set: { settings.speedUnit = $0 })) {
                            ForEach(SpeedUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    modernSection("App", system: "app.badge.fill") {
                        Toggle("Startup animation", isOn: $settings.startupAnimation).tint(.cyan)
                        Toggle("Startup sound", isOn: $settings.startupSound).tint(.cyan)
                        Toggle("Haptics", isOn: $settings.hapticsEnabled).tint(.cyan)
                        Toggle("Show raw packet logger", isOn: $settings.showRawPackets).tint(.cyan)
                    }

                    modernSection("Tuning Safety", system: "exclamationmark.shield.fill") {
                        Toggle("Tuning unlocked", isOn: Binding(
                            get: { settings.expertTuningUnlocked },
                            set: { newValue in
                                requestedTuningState = newValue
                                if newValue { showTuningWarning = true }
                                else {
                                    settings.expertTuningUnlocked = false
                                    showToast("Tuning locked", "Controller write controls are disabled.", "lock.fill")
                                }
                            }
                        ))
                        .tint(.orange)

                        Text("Tuning requires current settings to be read first and backs up values before writing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    modernSection("Connection", system: "antenna.radiowaves.left.and.right") {
                        Text(ble.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Auto connect to remembered bike", isOn: $settings.autoConnect).tint(.cyan)

                        HStack {
                            Button(ble.isScanning ? "Scanning..." : "Scan") { ble.startScan() }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                .disabled(ble.isScanning)

                            Button(ble.isDemoMode ? "Stop Demo" : "Demo Mode") {
                                ble.setDemoMode(!ble.isDemoMode)
                                showToast(ble.isDemoMode ? "Demo stopped" : "Demo started", ble.isDemoMode ? "Live demo values disabled." : "Realistic generated dashboard values enabled.", "speedometer")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    modernSection("HUD Layout", system: "rectangle.inset.filled") {
                        Toggle("Show kW", isOn: $settings.hudShowKW).tint(.cyan)
                        Toggle("Show temperatures", isOn: $settings.hudShowTemps).tint(.cyan)
                        Toggle("Show lean card", isOn: $settings.hudShowLeanCard).tint(.cyan)
                        Toggle("Show live graphs", isOn: $settings.hudShowGraphs).tint(.cyan)
                        Toggle("Show lean card", isOn: $settings.hudShowLeanCard).tint(.cyan)
                        Toggle("Show status icons", isOn: $settings.hudShowIcons).tint(.cyan)
                    }

                    if settings.developerUnlocked {
                        Button {
                            showDeveloperOptions = true
                        } label: {
                            HStack {
                                Image(systemName: "hammer.fill")
                                Text("Developer Options")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 82)
            }

            if let toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }

            if showTuningWarning {
                StyledConfirmDialog(
                    title: "Unlock tuning?",
                    message: "Changing controller parameters is your own responsibility. Read current settings and backup before writing.",
                    confirmTitle: "I Understand",
                    cancelTitle: "Cancel",
                    systemImage: "exclamationmark.triangle.fill",
                    destructive: true,
                    onConfirm: {
                        settings.expertTuningUnlocked = requestedTuningState
                        showTuningWarning = false
                        showToast("Tuning unlocked", "Read and backup settings before changing anything.", "exclamationmark.triangle.fill")
                    },
                    onCancel: {
                        settings.expertTuningUnlocked = false
                        showTuningWarning = false
                    }
                )
            }
        }
        .sheet(isPresented: $showDeveloperOptions) {
            DeveloperOptionsView()
                .environmentObject(settings)
                .environmentObject(ble)
                .presentationDetents([.medium, .large])
        }
    }

    private func modernSection<Content: View>(_ title: String, system: String, @ViewBuilder content: () -> Content) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: system)
                        .foregroundStyle(.cyan)
                    Text(title)
                        .font(.headline)
                }
                content()
            }
        }
    }

    private var footer: some View {
        GlassCard {
            VStack(spacing: 8) {
                Text("© 2026 APTUM – Always Progressing Toward Ultimate Mobility")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Text("Developed by crumies")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .onTapGesture {
                        devTapCount += 1
                        if devTapCount >= 5 && !settings.developerUnlocked {
                            settings.developerUnlocked = true
                            showToast("Developer menu unlocked", "Developer Options added to Settings.", "hammer.fill")
                        }
                    }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func showToast(_ title: String, _ message: String, _ icon: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            toast = AppToast(title: title, message: message, systemImage: icon)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.25)) {
                toast = nil
            }
        }
    }
}

struct DeveloperOptionsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ble: DunenBLEManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Update Frequency") {
                    Picker("Telemetry update", selection: Binding(get: { settings.updateInterval }, set: { newValue in
                        settings.updateInterval = newValue
                        ble.applyDeveloperUpdateInterval()
                    })) {
                        ForEach(UpdateInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                }

                Section("Bluetooth Info") {
                    row("Connected", ble.isConnected ? "Yes" : "No")
                    row("Demo", ble.isDemoMode ? "Yes" : "No")
                    row("Status", ble.connectionStatus)
                    row("Saved devices", "\(ble.savedDevices.count)")
                    row("Developer", ble.developerStatus)
                }

                Section("Developer Actions") {
                    Button("Clear Diagnostic History") {
                        ble.clearDiagnosticHistory()
                    }
                }

                Section("Demo Control") {
                    Toggle("App controls demo automatically", isOn: $settings.demoAutoInput)
                    Text(settings.demoAutoInput ? "Demo values move automatically." : "Manual overlay can control demo input when developer mode is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Remembered Devices") {
                    ForEach(ble.savedDevices) { device in
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Developer Options")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
