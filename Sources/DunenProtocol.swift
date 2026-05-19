import Foundation

enum DunenProtocol {
    static func readAllParametersFrame() -> Data {
        return Data([0xAA, 0x55, 0x03, 0x10, 0x00, UInt8(0x10 ^ 0x03)])
    }

    static func writeParameterFrame(id: Int, value: Double) -> Data {
        let scaled = Int32((value * 100).rounded())
        let lo = UInt8(id & 0xFF)
        let hi = UInt8((id >> 8) & 0xFF)
        let v0 = UInt8(UInt32(bitPattern: scaled) & 0xFF)
        let v1 = UInt8((UInt32(bitPattern: scaled) >> 8) & 0xFF)
        let v2 = UInt8((UInt32(bitPattern: scaled) >> 16) & 0xFF)
        let v3 = UInt8((UInt32(bitPattern: scaled) >> 24) & 0xFF)
        let bytes: [UInt8] = [0xAA, 0x55, 0x09, 0x21, lo, hi, v0, v1, v2, v3]
        return Data(bytes + [checksum(bytes)])
    }

    static func parseParameterValues(from data: Data) -> [Int: Double] {
        let b = [UInt8](data)
        var result: [Int: Double] = [:]
        guard b.count >= 6 else { return result }

        var i = 0
        while i + 5 < b.count {
            let id = Int(b[i]) | (Int(b[i + 1]) << 8)
            let raw = Int32(bitPattern:
                UInt32(b[i + 2]) |
                (UInt32(b[i + 3]) << 8) |
                (UInt32(b[i + 4]) << 16) |
                (UInt32(b[i + 5]) << 24)
            )
            if id > 0 && id < 400 {
                result[id] = Double(raw) / 100.0
            }
            i += 6
        }
        return result
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }
}
