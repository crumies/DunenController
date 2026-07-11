import Foundation

enum DunenProtocol {
    // DUNEN BB6D uses a Modbus-RTU-like protocol over BLE.
    // FFF2 = write request, FFE1 = notify/read response.
    // Function 0x03 reads holding registers/parameter blocks.
    static func modbusReadFrame(start: Int, count: Int) -> Data {
        let bytes: [UInt8] = [
            0x01,
            0x03,
            UInt8((start >> 8) & 0xFF),
            UInt8(start & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8(count & 0xFF)
        ]
        let crc = crc16(bytes)
        return Data(bytes + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)])
    }

    static func fastTelemetryProbeFrame() -> Data {
        // Seen from the official DUNEN app/nRF logs. Used as a live telemetry probe.
        return Data([0x01, 0x10, 0x03, 0xE8, 0x00, 0x12, 0xC0, 0x74])
    }

    static func readAllParametersFrame() -> Data {
        // User/tuning table first block, 24 registers.
        modbusReadFrame(start: 2, count: 24)
    }

    static func readLiveOutputFrame() -> Data {
        // Most useful output block: 338–361, includes RPM/voltage/SOC-ish surrounding blocks.
        modbusReadFrame(start: 338, count: 24)
    }

    static func readOutputParametersFrame() -> Data {
        // Output table start.
        modbusReadFrame(start: 266, count: 24)
    }

    static func outputPollFrames() -> [Data] {
        [
            modbusReadFrame(start: 266, count: 24), // 266–289: IADin9 (282) = current
            modbusReadFrame(start: 290, count: 24), // brake/gear/throttle/torque start
            modbusReadFrame(start: 314, count: 24), // 314–337: OTorq (321)
            modbusReadFrame(start: 338, count: 24), // 338–361: OVkey (343), OVMon5V (344), OVMon15V (345)
            modbusReadFrame(start: 362, count: 24), // 362–385: OVechSpd (362) = vehicle speed
            modbusReadFrame(start: 386, count: 24),
            modbusReadFrame(start: 410, count: 24)  // faults
        ]
    }

    static func tuningPollFrames() -> [Data] {
        [
            modbusReadFrame(start: 90, count: 24),
            modbusReadFrame(start: 210, count: 24)
        ]
    }

    static func writeParameterFrame(id: Int, value: Double) -> Data {
        // Keep the previous write method conservative for now.
        // Proper Modbus write will be added after one confirmed write capture.
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

    static func parseParameterValues(from data: Data, expectedStart: Int? = nil) -> [Int: Double] {
        let b = [UInt8](data)
        guard b.count >= 5 else { return [:] }

        // Modbus read response: 01 03 byteCount <register bytes> CRClo CRChi
        // DUNEN tables use 32-bit values: 0x30 bytes = 12 parameters.
        // Your log proved this because values are like 00 00 00 30, 00 00 00 34, etc.
        if b[0] == 0x01 && b[1] == 0x03 {
            let byteCount = Int(b[2])
            guard b.count >= 3 + byteCount else { return [:] }

            var result: [Int: Double] = [:]
            let start = expectedStart ?? 0
            var offset = 3

            for i in 0..<(byteCount / 4) {
                guard offset + 3 < b.count else { break }
                let raw = Int32(bitPattern:
                    (UInt32(b[offset]) << 24) |
                    (UInt32(b[offset + 1]) << 16) |
                    (UInt32(b[offset + 2]) << 8) |
                    UInt32(b[offset + 3])
                )
                result[start + i] = scaleValue(id: start + i, raw32: raw)
                offset += 4
            }
            return result
        }

                // Legacy/fallback guessed parser for older internal app packets.
        var result: [Int: Double] = [:]
        var i = 0
        while i + 5 < b.count {
            let id = Int(b[i]) | (Int(b[i + 1]) << 8)
            let raw = Int32(bitPattern:
                UInt32(b[i + 2]) |
                (UInt32(b[i + 3]) << 8) |
                (UInt32(b[i + 4]) << 16) |
                (UInt32(b[i + 5]) << 24)
            )
            if id > 0 && id < 500 {
                result[id] = Double(raw) / 100.0
            }
            i += 6
        }
        return result
    }

    private static func scaleValue(id: Int, raw32: Int32) -> Double {
        let v = Double(raw32)

        // Most DUNEN table values are raw integers or fixed-point.
        // The UI sanity filter decides what is usable.
        switch id {
        case 311...321:
            // OTorq (321): example value 1.8020 => raw is stored *10000
            return v / 10000.0
        case 282:
            // IADin9: analog current sample, raw / 100.0
            return v / 100.0
        case 335, 336, 343:
            // OVkey (343): battery voltage raw / 100.0
            return v / 100.0
        case 344, 345:
            // OVMon5V (344), OVMon15V (345): raw / 10000.0 (e.g. 51700 → 5.17 V)
            return v / 10000.0
        case 362:
            // OVechSpd: vehicle speed in km/h, raw / 100.0
            return v / 100.0
        default:
            return v
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 ^ $1 }
    }

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}
