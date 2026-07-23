import Foundation

enum TuningKind: String, Codable {
    case toggle
    case slider
    case picker
}

enum TuningGroup: String, CaseIterable, Codable {
    case vehicle     = "Vehicle"
    case brake       = "Brake"
    case throttle    = "Throttle"
    case common      = "Common"
}

struct TuningParameter: Identifiable, Codable, Equatable {
    var id: Int               // Modbus register address
    var internalName: String
    var displayName: String
    var detail: String
    var group: TuningGroup
    var kind: TuningKind
    var min: Double
    var max: Double
    var step: Double          // step size for sliders (default 0.01)
    var unit: String          // display unit label (empty = none)
    var currentValue: Double?
    var originalValue: Double?
    var pendingValue: Double?
    var isRisky: Bool

    var loaded: Bool { currentValue != nil }
    var hasChange: Bool {
        guard let currentValue, let pendingValue else { return false }
        return abs(currentValue - pendingValue) > 0.0001
    }

    // Convenience init with defaults for optional fields
    init(id: Int, internalName: String, displayName: String, detail: String,
         group: TuningGroup, kind: TuningKind, min: Double, max: Double,
         step: Double = 0.01, unit: String = "",
         currentValue: Double? = nil, originalValue: Double? = nil,
         pendingValue: Double? = nil, isRisky: Bool = false) {
        self.id = id; self.internalName = internalName; self.displayName = displayName
        self.detail = detail; self.group = group; self.kind = kind
        self.min = min; self.max = max; self.step = step; self.unit = unit
        self.currentValue = currentValue; self.originalValue = originalValue
        self.pendingValue = pendingValue; self.isRisky = isRisky
    }

    // ── Address formula: addr = (row - 2) × 2 ──────────────────────────────
    // Confirmed anchors:
    //   row 211 → addr 418 = PSpeedModMFedk  (known working ✓)
    //   row 212 → addr 420 = PSpeedModLFedk  (known working ✓)
    //   row 213 → addr 422 = PBrkCmdOffEn    (刹车断电使能)
    //   row 268 → addr 532 = PAccCurveSet1   (油门曲线设置点1)  …+2 per point
    //   row 324 → addr 644 = PMotorType      (电机型号)

    static let defaults: [TuningParameter] = [

        // ── VEHICLE ─────────────────────────────────────────────────────────
        // PMotorType  row 324 → addr 644
        // 0 = default type, 1 = alternate type (two power variants)
        .init(id: 644,
              internalName: "PMotorType",
              displayName: "Motor / Vehicle Type",
              detail: "Select the power variant of your vehicle. 0 = Standard, 1 = High-power. Change only if instructed by your dealer. Requires controller restart.",
              group: .vehicle, kind: .picker,
              min: 0, max: 1, step: 1, unit: "",
              isRisky: true),

        // ── BRAKE ────────────────────────────────────────────────────────────
        // PBrkCmdOffEn  row 213 → addr 422
        // 0 = brake does NOT cut motor power, 1 = brake cuts motor power (most common / safest)
        .init(id: 422,
              internalName: "PBrkCmdOffEn",
              displayName: "Brake Cutoff (刹车断电)",
              detail: "When enabled, squeezing the brake lever immediately cuts motor power. Highly recommended for safety. 0 = Off, 1 = On.",
              group: .brake, kind: .toggle,
              min: 0, max: 1, step: 1, unit: "",
              isRisky: false),

        // ── THROTTLE CURVE ───────────────────────────────────────────────────
        // PAccCurveSet1–15  rows 268–282 → addrs 532–560
        // Each point maps a throttle position segment (1/15 … 15/15) to a torque fraction (0.0–1.0).
        // Default from spec: 0.07, 0.13, 0.20, 0.26, 0.33, 0.40, 0.46, 0.53, 0.59, 0.66, 0.73, 0.79, 0.86, 0.92, 1.00
        .init(id: 532, internalName: "PAccCurveSet1",  displayName: "Throttle Point 1  (7%)",  detail: "Torque output at 1/15 throttle. Lower = softer takeoff.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 534, internalName: "PAccCurveSet2",  displayName: "Throttle Point 2  (13%)", detail: "Torque output at 2/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 536, internalName: "PAccCurveSet3",  displayName: "Throttle Point 3  (20%)", detail: "Torque output at 3/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 538, internalName: "PAccCurveSet4",  displayName: "Throttle Point 4  (27%)", detail: "Torque output at 4/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 540, internalName: "PAccCurveSet5",  displayName: "Throttle Point 5  (33%)", detail: "Torque output at 5/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 542, internalName: "PAccCurveSet6",  displayName: "Throttle Point 6  (40%)", detail: "Torque output at 6/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 544, internalName: "PAccCurveSet7",  displayName: "Throttle Point 7  (47%)", detail: "Torque output at 7/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 546, internalName: "PAccCurveSet8",  displayName: "Throttle Point 8  (53%)", detail: "Torque output at 8/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 548, internalName: "PAccCurveSet9",  displayName: "Throttle Point 9  (60%)", detail: "Torque output at 9/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 550, internalName: "PAccCurveSet10", displayName: "Throttle Point 10 (67%)", detail: "Torque output at 10/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 552, internalName: "PAccCurveSet11", displayName: "Throttle Point 11 (73%)", detail: "Torque output at 11/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 554, internalName: "PAccCurveSet12", displayName: "Throttle Point 12 (80%)", detail: "Torque output at 12/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 556, internalName: "PAccCurveSet13", displayName: "Throttle Point 13 (87%)", detail: "Torque output at 13/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 558, internalName: "PAccCurveSet14", displayName: "Throttle Point 14 (93%)", detail: "Torque output at 14/15 throttle.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),
        .init(id: 560, internalName: "PAccCurveSet15", displayName: "Throttle Point 15 (100%)", detail: "Torque output at full throttle. Always keep at 1.0.", group: .throttle, kind: .slider, min: 0, max: 1, step: 0.01, unit: ""),

        // ── COMMON ───────────────────────────────────────────────────────────
        .init(id: 194, internalName: "PIDLLDTorqCurveSet1", displayName: "Side Support Function",
              detail: "Kickstand / side support sensor. 0 = Off, 1 = On.",
              group: .common, kind: .toggle, min: 0, max: 1, isRisky: true),
        .init(id: 418, internalName: "PSpeedModMFedk", displayName: "Rollback Prevention",
              detail: "Anti-rollback / hill-hold function. 0 = Off, 1 = On.",
              group: .common, kind: .toggle, min: 0, max: 1, isRisky: true),
        .init(id: 420, internalName: "PSpeedModLFedk", displayName: "Cruise Control",
              detail: "Cruise control enable. 0 = Off, 1 = On.",
              group: .common, kind: .toggle, min: 0, max: 1, isRisky: true),
    ]
}
