import Foundation
import SwiftUI

enum AppTab: String, CaseIterable {
    case dashboard = "Dash"
    case advanced = "Info"
    case tuning = "Tuning"
    case diagnostics = "Diag"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .advanced: return "list.bullet.rectangle"
        case .tuning: return "slider.horizontal.3"
        case .diagnostics: return "waveform.path.ecg.rectangle"
        case .settings: return "gearshape.fill"
        }
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh = "KM/H"
    case mph = "MPH"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"
    var id: String { rawValue }
}

enum UpdateInterval: Double, CaseIterable, Identifiable {
    case tenth = 0.1
    case quarter = 0.25
    case half = 0.5
    case one = 1.0
    case two = 2.0

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .tenth: return "0.1s"
        case .quarter: return "0.25s"
        case .half: return "0.5s"
        case .one: return "1s"
        case .two: return "2s"
        }
    }
}

enum RideMode: String, CaseIterable, Codable, Identifiable {
    case eco = "ECO"
    case xc = "XC"
    case sports = "SPORTS"
    case reverse = "R"
    case park = "P"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eco: return "ECO"
        case .xc: return "XC"
        case .sports: return "SPORTS"
        case .reverse: return "REVERSE"
        case .park: return "PARK"
        }
    }

    var symbol: String {
        switch self {
        case .eco: return "leaf.fill"
        case .xc: return "bolt.fill"
        case .sports: return "flame.fill"
        case .reverse: return "arrow.uturn.backward.circle.fill"
        case .park: return "parkingsign.circle.fill"
        }
    }
}

final class AppSettings: ObservableObject {
    @AppStorage("speedUnit") var speedUnitRaw: String = SpeedUnit.kmh.rawValue
    @AppStorage("appearanceMode") var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage("startupAnimation") var startupAnimation: Bool = true
    @AppStorage("showRawPackets") var showRawPackets: Bool = true
    @AppStorage("expertTuningUnlocked") var expertTuningUnlocked: Bool = false
    @Published var developerUnlocked: Bool = false
    @AppStorage("updateInterval") var updateIntervalRaw: Double = 0.1
    @AppStorage("autoConnect") var autoConnect: Bool = true
    @AppStorage("startupSound") var startupSound: Bool = true
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("focusHUD") var focusHUD: Bool = false
    @AppStorage("batteryCapacityAh") var batteryCapacityAh: Double = 38.4
    @AppStorage("nominalVoltage") var nominalVoltage: Double = 72.0
    @AppStorage("motorContinuousW") var motorContinuousW: Double = 4000
    @AppStorage("motorPeakW") var motorPeakW: Double = 8000
    @AppStorage("hudShowKW") var hudShowKW: Bool = true
    @AppStorage("hudShowTemps") var hudShowTemps: Bool = true
    @AppStorage("hudShowLean") var hudShowLean: Bool = true
    @AppStorage("hudShowGraphs") var hudShowGraphs: Bool = true
    @AppStorage("hudShowIcons") var hudShowIcons: Bool = true
    @AppStorage("liveActivityEnabled") var liveActivityEnabled: Bool = false
    @AppStorage("hudShowMetricsCard") var hudShowMetricsCard: Bool = true
    @AppStorage("hudShowRideRecording") var hudShowRideRecording: Bool = false
    @AppStorage("hudShowBatteryCard") var hudShowBatteryCard: Bool = false
    @AppStorage("hudShowDiagnosticsCard") var hudShowDiagnosticsCard: Bool = false
    @AppStorage("hudShowLeanCard") var hudShowLeanCard: Bool = false
    @AppStorage("demoAutoInput") var demoAutoInput: Bool = true

    var speedUnit: SpeedUnit {
        get { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }
        set { speedUnitRaw = newValue.rawValue }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    var updateInterval: UpdateInterval {
        get { UpdateInterval(rawValue: updateIntervalRaw) ?? .tenth }
        set { updateIntervalRaw = newValue.rawValue }
    }
}

struct Telemetry: Equatable {
    var speedKmh: Double = 0
    var rpm: Int = 0
    var voltage: Double = 0
    var currentA: Double = 0
    var powerKw: Double = 0
    var batteryPercent: Double = 0
    var odometerKm: Double = 0
    var warningCode: Int = 0
    var errorCode: Int = 0
    var phaseVoltage: Double = 0
    var motorAngle: Int = 0
    var torque: Double = 0
    var zeroAngle: Int = 0
    var motorTemp: Double = 0
    var controllerTemp: Double = 0
    var leanAngle: Double = 0
    var gForce: Double = 0
    var wheelRPM: Double = 0
    var wheelTorqueNm: Double = 0
    var theoreticalTopSpeedKmh: Double = 0
    var voltageSag: Double = 0
    var mode: RideMode = .xc
    var headlightActive: Bool = false
    var brakeActive: Bool = false
    var kickstandActive: Bool = false
    var parkingActive: Bool = false
    var reverseActive: Bool = false
    var rawHex: String = ""
    var packetCount: Int = 0
    var productModel: String = "DEMCC2416QS035ZFS01"
    var controllerName: String = "DUNEN312"
}

struct TelemetryHistory {
    var speed: [Double] = []
    var rpm: [Double] = []
    var voltage: [Double] = []
    var current: [Double] = []

    mutating func append(_ t: Telemetry) {
        speed.append(t.speedKmh)
        rpm.append(Double(t.rpm))
        voltage.append(t.voltage)
        current.append(t.currentA)
        trim()
    }

    mutating func trim() {
        let maxCount = 90
        if speed.count > maxCount { speed.removeFirst(speed.count - maxCount) }
        if rpm.count > maxCount { rpm.removeFirst(rpm.count - maxCount) }
        if voltage.count > maxCount { voltage.removeFirst(voltage.count - maxCount) }
        if current.count > maxCount { current.removeFirst(current.count - maxCount) }
    }
}

struct SavedDevice: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var lastRSSI: Int
    var lastSeen: Date
}

struct RideStats: Codable, Equatable {
    var isRecording: Bool = false
    var startedAt: Date?
    var durationSeconds: Double = 0
    var topSpeedKmh: Double = 0
    var averageSpeedKmh: Double = 0
    var tripKm: Double = 0
    var batteryStartVoltage: Double?
    var batteryUsedVoltage: Double = 0
    var zeroToFiftySeconds: Double?
    var peakRPM: Int = 0
    var peakCurrentA: Double = 0
    var sampleCount: Int = 0

    mutating func reset() {
        self = RideStats()
    }
}

struct DiagnosticEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var title: String
    var detail: String
    var severity: String
}

struct AppToast: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var systemImage: String = "checkmark.circle.fill"
}
