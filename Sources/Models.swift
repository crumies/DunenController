import Foundation
import SwiftUI

enum AppTab: String, CaseIterable {
    case info = "Info"
    case advanced = "Advanced"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .info: return "gauge.with.dots.needle.bottom.50percent"
        case .advanced: return "chart.bar.xaxis"
        case .settings: return "gearshape.fill"
        }
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh = "KM/H"
    case mph = "MPH"
    var id: String { rawValue }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case km = "KM"
    case miles = "Miles"
    var id: String { rawValue }
}

final class AppSettings: ObservableObject {
    @AppStorage("speedUnit") var speedUnitRaw: String = SpeedUnit.kmh.rawValue
    @AppStorage("distanceUnit") var distanceUnitRaw: String = DistanceUnit.km.rawValue
    @AppStorage("demoMode") var demoMode: Bool = true
    @AppStorage("startupAnimation") var startupAnimation: Bool = true
    @AppStorage("glowIntensity") var glowIntensity: Double = 0.85

    var speedUnit: SpeedUnit {
        get { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }
        set { speedUnitRaw = newValue.rawValue }
    }

    var distanceUnit: DistanceUnit {
        get { DistanceUnit(rawValue: distanceUnitRaw) ?? .km }
        set { distanceUnitRaw = newValue.rawValue }
    }
}

struct Telemetry: Equatable {
    var speedKmh: Double = 0
    var rpm: Int = 0
    var voltage: Double = 0
    var soc: Double = 0
    var controllerTemp: Double = 0
    var motorTemp: Double = 0
    var throttlePercent: Double = 0
    var currentA: Double = 0
    var phaseCurrentA: Double = 0
    var frontBrakePressed: Bool = false
    var rearBrakePressed: Bool = false
    var regenActive: Bool = false
    var tiltFrontBack: Double = 0
    var tiltLeftRight: Double = 0
    var faultText: String = "None"
    var rawHex: String = ""
    var packetCount: Int = 0

    static let demo = Telemetry(
        speedKmh: 68,
        rpm: 5320,
        voltage: 78.6,
        soc: 72,
        controllerTemp: 38,
        motorTemp: 42,
        throttlePercent: 34,
        currentA: 42,
        phaseCurrentA: 128,
        frontBrakePressed: false,
        rearBrakePressed: true,
        regenActive: true,
        tiltFrontBack: 2,
        tiltLeftRight: -1,
        faultText: "None",
        rawHex: "AA 55 35 01 44 14 32 1E 02 00 52 03 00 00",
        packetCount: 128
    )
}
