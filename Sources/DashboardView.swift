import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    @State private var fullscreen = false

    var odo: String {
        settings.speedUnit == .kmh ? String(format: "%.1f km", ble.telemetry.odometerKm) : String(format: "%.1f mi", ble.telemetry.odometerKm * 0.621371)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                HUDBlock(fullscreenButton: { fullscreen = true }, compact: false)

                if settings.hudShowMetricsCard {
                    MetricsCard(odo: odo)
                }

                if settings.hudShowGraphs {
                    GraphPanel(fullscreenButton: { fullscreen = true }, compact: false)
                }

                if settings.hudShowBatteryCard {
                    BatteryHealthCard()
                }

                if settings.hudShowLeanCard {
                    LeanCard()
                }

                if settings.hudShowRideRecording {
                    RideRecordingCard()
                }

                if settings.hudShowDiagnosticsCard {
                    MiniDiagnosticsCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 82)
        }
        .fullScreenCover(isPresented: $fullscreen) {
            FullscreenHUD()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            ConnectionPill()
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let name = ble.connectedName {
                    Text("Connected to \(name)")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

struct MetricsCard: View {
    @EnvironmentObject var ble: DunenBLEManager
    let odo: String

    private var gearText: String {
        if ble.telemetry.mode == .park { return "P" }
        if ble.telemetry.mode == .reverse { return "R" }
        switch ble.telemetry.speedModeRaw {
        case 0: return "ECO"
        case 1: return "XC"
        case 2: return "SPORTS"
        default: return ble.telemetry.mode.rawValue
        }
    }

    var body: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack {
                    metric("Voltage", String(format: "%.2f V", ble.telemetry.voltage))
                    metric("Odometer", odo)
                }
                HStack {
                    metric("Current", String(format: "%.1f A", ble.telemetry.currentA))
                    metric("Battery", String(format: "%.0f %%", ble.telemetry.batteryPercent))
                }
                HStack {
                    metric("Gear", gearText)
                    metric("Regen", ble.telemetry.regenLevel > 0 ? "Level \(ble.telemetry.regenLevel)" : "Auto")
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HUDBlock: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    var fullscreenButton: (() -> Void)?
    var compact: Bool = false

    var speedValue: Double {
        settings.speedUnit == .kmh ? ble.telemetry.speedKmh : ble.telemetry.speedKmh * 0.621371
    }

    var displaySpeed: String {
        if ble.telemetry.mode == .park { return "P" }
        return "\(Int(speedValue.rounded()))"
    }

    var body: some View {
        GlassCard(glow: true) {
            ZStack {
                Circle()
                    .fill(modeColor.opacity(0.16 + min(ble.telemetry.speedKmh / 260, 0.22)))
                    .blur(radius: 52)
                    .frame(width: compact ? 210 : 260)

                VStack(spacing: compact ? 7 : 10) {
                    AptumLogoImage()
                        .frame(width: compact ? 132 : 150, height: compact ? 34 : 40)
                        .padding(.bottom, -2)

                    ModeBadge(mode: ble.telemetry.mode)

                    if settings.hudShowTemps {
                        HStack {
                            statusIcon("cpu", String(format: "%.0f°C", ble.telemetry.controllerTemp))
                            Spacer()
                            motorTempIcon(String(format: "%.0f°C", ble.telemetry.motorTemp))
                            Spacer()
                            statusIcon("battery.75percent", String(format: "%.0f%%", ble.telemetry.batteryPercent))
                        }
                    }

                    ZStack {
                        RPMArc(rpm: ble.telemetry.rpm, mode: ble.telemetry.mode)
                            .frame(width: compact ? 205 : 225, height: compact ? 205 : 225)

                        VStack(spacing: 0) {
                            Text(displaySpeed)
                                .font(.system(size: ble.telemetry.mode == .park ? (compact ? 92 : 108) : (compact ? 76 : 88), weight: .heavy, design: .rounded))
                                .foregroundStyle(ble.telemetry.mode == .sports ? .orange : (ble.telemetry.mode == .park ? .white : .primary))
                            Text(ble.telemetry.mode == .park ? "PARK" : (ble.telemetry.mode == .reverse ? "REVERSE • \(settings.speedUnit.rawValue)" : settings.speedUnit.rawValue))
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if settings.hudShowKW {
                        Text(String(format: "%.1f kW", ble.telemetry.powerKw))
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.22))
                            .clipShape(Capsule())
                    }

                    Text(Date.now.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if settings.hudShowIcons {
                        HStack {
                            smallState("light.max.fill", active: ble.telemetry.headlightActive)
                            smallState("exclamationmark.circle.fill", active: ble.telemetry.warningCode != 0 || ble.telemetry.errorCode != 0)
                            smallState("parkingsign.circle.fill", active: ble.telemetry.parkingActive)
                            smallState("arrow.uturn.backward.circle.fill", active: ble.telemetry.reverseActive)
                            smallState("figure.stand", active: ble.telemetry.kickstandActive)
                            smallState("brakesignal", active: ble.telemetry.brakeActive)
                            Spacer()
                            if let fullscreenButton {
                                Button {
                                    fullscreenButton()
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                }
                                .buttonStyle(.bordered)
                                .tint(.cyan)
                            }
                        }
                    }
                }
            }
        }
    }

    var modeColor: Color {
        switch ble.telemetry.mode {
        case .eco: return .green
        case .xc: return .cyan
        case .sports: return .orange
        case .reverse: return .purple
        case .park: return .white
        }
    }

    private func statusIcon(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.cyan)
            Text(text).font(.caption.weight(.bold))
        }
    }

    private func electricMotorIcon(_ text: String) -> some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.cyan, lineWidth: 1.6)
                    .frame(width: 18, height: 13)
                Circle()
                    .stroke(.cyan, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(.cyan)
                    .frame(width: 3, height: 7)
                    .offset(x: 11)
                Rectangle()
                    .fill(.cyan)
                    .frame(width: 3, height: 7)
                    .offset(x: -11)
            }
            Text(text).font(.caption.weight(.bold))
        }
    }

    private func motorTempIcon(_ text: String) -> some View {
        HStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.cyan, lineWidth: 1.6)
                    .frame(width: 18, height: 13)
                Circle()
                    .stroke(.cyan, lineWidth: 1.3)
                    .frame(width: 5, height: 5)
                Rectangle()
                    .fill(.cyan)
                    .frame(width: 3, height: 6)
                    .offset(x: 11)
            }
            Text(text).font(.caption.weight(.bold))
        }
    }

    private func smallState(_ icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .foregroundStyle(active ? .cyan : .secondary.opacity(0.4))
            .font(.caption)
    }
}

struct LeanIndicator: View {
    @EnvironmentObject var ble: DunenBLEManager

    var side: String {
        if ble.telemetry.leanAngle > 2 { return "RIGHT" }
        if ble.telemetry.leanAngle < -2 { return "LEFT" }
        return "CENTER"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("LEAN \(side)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f°", abs(ble.telemetry.leanAngle)))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
            }

            GeometryReader { geo in
                ZStack {
                    Capsule().fill(.white.opacity(0.12))
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 2)
                    Circle()
                        .fill(.cyan)
                        .frame(width: 10, height: 10)
                        .offset(x: CGFloat(max(-1, min(1, ble.telemetry.leanAngle / 42))) * geo.size.width / 2)
                }
            }
            .frame(height: 10)
        }
    }
}

struct LeanCard: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lean Angle").font(.headline)
                LeanIndicator()
            }
        }
    }
}

struct ModeBadge: View {
    let mode: RideMode

    var color: Color {
        switch mode {
        case .eco: return .green
        case .xc: return .cyan
        case .sports: return .orange
        case .reverse: return .purple
        case .park: return .white
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.symbol)
            Text(mode.rawValue)
        }
        .font(.headline.weight(.heavy))
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct RPMArc: View {
    let rpm: Int
    let mode: RideMode

    private let startTrim = 0.12
    private let totalTrim = 0.76

    // Controller/software RPM limits
    var modeLimitRPM: Double {
        switch mode {
        case .eco: return 4000
        case .xc: return 6000
        case .sports: return 8000
        case .reverse: return 350
        case .park: return 1000
        }
    }

    // Realistic road-speed goals per mode.
    // This changes how much the meter moves in each mode.
    var realisticTopSpeedKmh: Double {
        switch mode {
        case .eco: return 65
        case .xc: return 90
        case .sports: return 112
        case .reverse: return 9
        case .park: return 0
        }
    }

    // RPM that equals the realistic road-speed goal.
    // Uses Aptum reference: 8000 RPM ≈ 136 km/h wheel-in-air/software top.
    var realisticTopRPM: Double {
        switch mode {
        case .eco: return min(modeLimitRPM, realisticTopSpeedKmh * 8000.0 / 136.0)
        case .xc: return min(modeLimitRPM, realisticTopSpeedKmh * 8000.0 / 136.0)
        case .sports: return min(modeLimitRPM, realisticTopSpeedKmh * 8000.0 / 136.0)
        case .reverse: return 300
        case .park: return 1000
        }
    }

    // Display max has headroom after realistic top so it does not peg.
    var displayMaxRPM: Double {
        switch mode {
        case .eco: return realisticTopRPM + 850
        case .xc: return realisticTopRPM + 1050
        case .sports: return realisticTopRPM + 1300
        case .reverse: return 520
        case .park: return 1500
        }
    }

    // Earlier redline per mode.
    var redlineStartRPM: Double {
        switch mode {
        case .eco: return realisticTopRPM * 0.42
        case .xc: return realisticTopRPM * 0.46
        case .sports: return realisticTopRPM * 0.50
        case .reverse: return 55
        case .park: return 350
        }
    }

    // Final danger color appears before realistic top.
    var fullRedlineRPM: Double {
        switch mode {
        case .eco: return realisticTopRPM - 650
        case .xc: return realisticTopRPM - 750
        case .sports: return realisticTopRPM - 850
        case .reverse: return 185
        case .park: return 700
        }
    }

    var progress: Double {
        min(max(Double(rpm) / displayMaxRPM, 0), 0.985)
    }

    var stops: [Gradient.Stop] {
        let start = max(0.01, min(redlineStartRPM / displayMaxRPM, 0.90))
        let full = max(start + 0.02, min(fullRedlineRPM / displayMaxRPM, 0.95))

        switch mode {
        case .eco:
            return [
                .init(color: .green, location: 0),
                .init(color: .green, location: start),
                .init(color: .yellow, location: start + ((full-start) * 0.45)),
                .init(color: .orange, location: start + ((full-start) * 0.72)),
                .init(color: .red, location: full),
                .init(color: .red, location: 1)
            ]
        case .xc:
            return [
                .init(color: .cyan, location: 0),
                .init(color: .cyan, location: start),
                .init(color: .blue, location: start + ((full-start) * 0.42)),
                .init(color: .purple, location: start + ((full-start) * 0.70)),
                .init(color: .red, location: full),
                .init(color: .red, location: 1)
            ]
        case .sports:
            return [
                .init(color: .orange, location: 0),
                .init(color: .orange, location: start),
                .init(color: .red, location: start + ((full-start) * 0.50)),
                .init(color: Color(red: 0.22, green: 0.0, blue: 0.0), location: start + ((full-start) * 0.75)),
                .init(color: .black, location: full),
                .init(color: .black, location: 1)
            ]
        case .reverse:
            return [
                .init(color: .purple, location: 0),
                .init(color: .purple, location: start),
                .init(color: .pink, location: start + ((full-start) * 0.55)),
                .init(color: .red, location: full),
                .init(color: .red, location: 1)
            ]
        case .park:
            return [
                .init(color: .white, location: 0),
                .init(color: .white.opacity(0.7), location: 1)
            ]
        }
    }

    var shadowColor: Color {
        switch mode {
        case .eco: return .green
        case .xc: return .cyan
        case .sports: return .orange
        case .reverse: return .purple
        case .park: return .white
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: startTrim, to: startTrim + totalTrim)
                .stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: startTrim, to: startTrim + progress * totalTrim)
                .stroke(
                    AngularGradient(gradient: Gradient(stops: stops), center: .center),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
                .shadow(color: shadowColor.opacity(0.35), radius: 10)
        }
    }
}

struct GraphPanel: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    var fullscreenButton: () -> Void
    var compact: Bool = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: compact ? 7 : 11) {
                HStack {
                    Text("Dynamic Live Graphs").font(.headline)
                    Spacer()
                    if !compact {
                        Button { fullscreenButton() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.bordered).tint(.cyan)
                    }
                }

                graphRow("Speed", value: String(format: "%.0f %@", settings.speedUnit == .kmh ? ble.telemetry.speedKmh : ble.telemetry.speedKmh * 0.621371, settings.speedUnit.rawValue), values: ble.history.speed, max: 120)
                graphRow("RPM", value: "\(ble.telemetry.rpm) rpm", values: ble.history.rpm, max: 9000)
                graphRow("Voltage", value: String(format: "%.2f V", ble.telemetry.voltage), values: ble.history.voltage, max: 90)
                graphRow("Current", value: String(format: "%.1f A", ble.telemetry.currentA), values: ble.history.current, max: 140)
            }
        }
    }

    private func graphRow(_ title: String, value: String, values: [Double], max: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.bold)).foregroundStyle(title == "Speed" ? .cyan : .primary)
            }
            MiniLineGraph(values: values, maxValue: max).frame(height: compact ? 34 : 44)
        }
    }
}

struct BatteryHealthCard: View {
    @EnvironmentObject var ble: DunenBLEManager

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Battery Health").font(.headline)
                HStack {
                    stat("Pack", "72V 38.4Ah")
                    stat("Percent", String(format: "%.0f%%", ble.telemetry.batteryPercent))
                    stat("Sag", String(format: "%.2fV", ble.telemetry.voltageSag))
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity)
    }
}

struct MiniDiagnosticsCard: View {
    @EnvironmentObject var ble: DunenBLEManager

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mini Diagnostics").font(.headline)
                HStack {
                    stat("Warn", "\(ble.telemetry.warningCode)")
                    stat("Err", "\(ble.telemetry.errorCode)")
                    stat("Packets", "\(ble.telemetry.packetCount)")
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold))
        }
        .frame(maxWidth: .infinity)
    }
}

struct RideRecordingCard: View {
    @EnvironmentObject var ble: DunenBLEManager

    var body: some View {
        GlassCard(glow: ble.rideStats.isRecording) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Ride Recording").font(.headline)
                    Spacer()
                    Button(ble.rideStats.isRecording ? "Stop" : "Start") {
                        ble.rideStats.isRecording ? ble.stopRideRecording() : ble.startRideRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ble.rideStats.isRecording ? .red : .cyan)
                }

                HStack {
                    stat("Top", String(format: "%.0f km/h", ble.rideStats.topSpeedKmh))
                    stat("Avg", String(format: "%.0f km/h", ble.rideStats.averageSpeedKmh))
                    stat("0–50", ble.rideStats.zeroToFiftySeconds == nil ? "—" : String(format: "%.2fs", ble.rideStats.zeroToFiftySeconds!))
                }

                HStack {
                    stat("Trip", String(format: "%.2f km", ble.rideStats.tripKm))
                    stat("Peak RPM", "\(ble.rideStats.peakRPM)")
                    stat("Battery", String(format: "-%.2f V", ble.rideStats.batteryUsedVoltage))
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FullscreenHUD: View {
    @EnvironmentObject var ble: DunenBLEManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Circle()
                .fill(modeColor.opacity(0.20))
                .blur(radius: 90)
                .frame(width: 380)
                .offset(y: -40)

            ScrollView {
                VStack(spacing: 8) {
                    HUDBlock(fullscreenButton: nil, compact: true)
                        .frame(maxWidth: 430)

                    if settings.hudShowMetricsCard {
                        MetricsCard(odo: settings.speedUnit == .kmh ? String(format: "%.1f km", ble.telemetry.odometerKm) : String(format: "%.1f mi", ble.telemetry.odometerKm * 0.621371))
                            .frame(maxWidth: 430)
                    }

                    if settings.hudShowGraphs {
                        GraphPanel(fullscreenButton: {}, compact: true)
                            .frame(maxWidth: 430)
                    }

                    if settings.hudShowBatteryCard {
                        BatteryHealthCard()
                            .frame(maxWidth: 430)
                    }

                    if settings.hudShowLeanCard {
                        LeanCard()
                            .frame(maxWidth: 430)
                    }

                    if settings.hudShowRideRecording {
                        RideRecordingCard()
                            .frame(maxWidth: 430)
                    }

                    if settings.hudShowDiagnosticsCard {
                        MiniDiagnosticsCard()
                            .frame(maxWidth: 430)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 58)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                HUDAddMenu()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .overlay(Circle().stroke(.cyan.opacity(0.35), lineWidth: 1))
                        .clipShape(Circle())
                        .shadow(color: .cyan.opacity(0.25), radius: 14)
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Live Activity removed
        }
    }

    var modeColor: Color {
        switch ble.telemetry.mode {
        case .eco: return .green
        case .xc: return .cyan
        case .sports: return .orange
        case .reverse: return .purple
        case .park: return .white
        }
    }
}

struct HUDAddMenu: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Menu {
            Toggle("Metrics card", isOn: $settings.hudShowMetricsCard)
            Toggle("Graphs", isOn: $settings.hudShowGraphs)
            Toggle("Battery card", isOn: $settings.hudShowBatteryCard)
            Toggle("Ride recording", isOn: $settings.hudShowRideRecording)
            Toggle("Mini diagnostics", isOn: $settings.hudShowDiagnosticsCard)
            Divider()
            Toggle("kW readout", isOn: $settings.hudShowKW)
            Toggle("Temperatures", isOn: $settings.hudShowTemps)
            Toggle("Lean card", isOn: $settings.hudShowLeanCard)
            Toggle("Status icons", isOn: $settings.hudShowIcons)
        } label: {
            Image(systemName: "plus")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .overlay(Circle().stroke(.cyan.opacity(0.35), lineWidth: 1))
                .clipShape(Circle())
                .shadow(color: .cyan.opacity(0.25), radius: 14)
        }
    }
}
