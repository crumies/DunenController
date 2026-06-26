import Foundation

enum TuningKind: String, Codable {
    case toggle
}

enum TuningGroup: String, CaseIterable, Codable {
    case common = "Common"
}

struct TuningParameter: Identifiable, Codable, Equatable {
    var id: Int
    var internalName: String
    var displayName: String
    var detail: String
    var group: TuningGroup
    var kind: TuningKind
    var min: Double
    var max: Double
    var currentValue: Double?
    var originalValue: Double?
    var pendingValue: Double?
    var isRisky: Bool

    var loaded: Bool { currentValue != nil }
    var hasChange: Bool {
        guard let currentValue, let pendingValue else { return false }
        return abs(currentValue - pendingValue) > 0.0001
    }

    static let defaults: [TuningParameter] = [
        .init(id: 99, internalName: "PIDLLDTorqCurveSet1", displayName: "Side Support Function", detail: "Kickstand / side support sensor function. 0 = Off, 1 = On.", group: .common, kind: .toggle, min: 0, max: 1, currentValue: nil, originalValue: nil, pendingValue: nil, isRisky: true),
        .init(id: 211, internalName: "FunParm2", displayName: "Rollback Prevention", detail: "Anti sliding slope / rollback prevention function. 0 = Off, 1 = On.", group: .common, kind: .toggle, min: 0, max: 1, currentValue: nil, originalValue: nil, pendingValue: nil, isRisky: true),
        .init(id: 212, internalName: "FunParm3", displayName: "Cruise Control", detail: "Cruise control enable. 0 = Off, 1 = On.", group: .common, kind: .toggle, min: 0, max: 1, currentValue: nil, originalValue: nil, pendingValue: nil, isRisky: true)
    ]
}
