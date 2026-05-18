import Foundation
import SwiftUI

enum AppTab: String, CaseIterable {
    case info = "Info"
    case advanced = "Advanced"
    case diagnostics = "Diagnostics"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .info: return "gauge.with.dots.needle.bottom.50percent"
        case .advanced: return "chart.bar.xaxis"
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

final class AppSettings: ObservableObject {
    @AppStorage("speedUnit") var speedUnitRaw: String = SpeedUnit.kmh.rawValue
    @AppStorage("demoMode") var demoMode: Bool = true
    @AppStorage("startupAnimation") var startupAnimation: Bool = true
    @AppStorage("showRawPackets") var showRawPackets: Bool = true
    @AppStorage("autoReconnect") var autoReconnect: Bool = true
    @AppStorage("glowIntensity") var glowIntensity: Double = 0.85

    var speedUnit: SpeedUnit {
        get { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }
        set { speedUnitRaw = newValue.rawValue }
    }
}

struct Telemetry: Equatable {
    var speedKmh: Double = 0
    var rpm: Int = 0
    var odometerKm: Double = 0
    var voltage: Double = 0
    var soc: Double = 0
    var controllerTemp: Double = 0
    var motorTemp: Double = 0
    var throttlePercent: Double = 0
    var currentA: Double = 0
    var phaseCurrentA: Double = 0

    var frontBrakePressed: Bool = false
    var rearBrakePressed: Bool = false
    var parkBrakePressed: Bool = false
    var standSensorActive: Bool = false
    var reverseActive: Bool = false
    var regenActive: Bool = false
    var ecoMode: Bool = false
    var sportMode: Bool = false

    var tiltFrontBack: Double = 0
    var tiltLeftRight: Double = 0

    var controllerModel: String = "DUNEN312"
    var productModel: String = "DEMCC2416QS035ZFS01"
    var bleService: String = "FFE0"
    var bleCharacteristic: String = "FFE1"
    var firmwareText: String = "Unknown"
    var faultText: String = "None"
    var protectionState: String = "Normal"

    var rawHex: String = ""
    var packetCount: Int = 0

    static let demo = Telemetry(
        speedKmh: 68.4,
        rpm: 5320,
        odometerKm: 742.6,
        voltage: 78.6,
        soc: 72,
        controllerTemp: 38,
        motorTemp: 42,
        throttlePercent: 34,
        currentA: 42,
        phaseCurrentA: 128,
        frontBrakePressed: false,
        rearBrakePressed: true,
        parkBrakePressed: false,
        standSensorActive: false,
        reverseActive: false,
        regenActive: true,
        ecoMode: false,
        sportMode: true,
        tiltFrontBack: 2.0,
        tiltLeftRight: -1.0,
        controllerModel: "DUNEN312",
        productModel: "DEMCC2416QS035ZFS01",
        bleService: "FFE0",
        bleCharacteristic: "FFE1",
        firmwareText: "6.8.0 style",
        faultText: "None",
        protectionState: "Normal",
        rawHex: "AA 55 35 01 44 14 32 1E 48 26 2A 22 2A 00 05 00 3A 1D 00",
        packetCount: 128
    )
}
