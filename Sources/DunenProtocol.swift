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
        // Function-code parameter table: address = (row-2)*2.
        // Row 99  → addr 194 = 0xC2 (Side Support / toggle params area)
        // Row 211 → addr 418 = 0x1A2 (FunParm2 Rollback, FunParm3 Cruise)
        [
            modbusReadFrame(start: 194, count: 24),
            modbusReadFrame(start: 418, count: 24)
        ]
    }

    /// Write a single 32-bit parameter using Modbus function 0x10 (write multiple registers).
    /// id = Modbus register address (= (row - 2) * 2 from the parameter table).
    /// For U32 params: value is the raw integer. For IQ16 params: value = decimal, encoded as Int32(value * 65536).
    /// isIQ16: pass true for IQ16 fractional parameters, false for U32 integer parameters.
    static func writeParameterFrame(id: Int, value: Double, isIQ16: Bool = false) -> Data {
        // Modbus function 0x10: write 2 registers (one 32-bit param) at address id.
        // Frame: [01] [10] [addrH] [addrL] [00] [02] [00] [dataH_hi] [dataH_lo] [dataL_hi] [dataL_lo] [CRCH] [CRCL]
        // The 32-bit value is split into two 16-bit registers (HIGH then LOW).
        let raw32: Int32
        if isIQ16 {
            // IQ16 encoding: (integer << 16) | (fraction * 65536)
            // But DUNEN stores as HIGH=fraction, LOW=integer (per live frame analysis).
            let intPart = Int32(value)
            let fracPart = Int32(((value - Double(intPart)) * 65536.0).rounded())
            raw32 = (fracPart << 16) | (intPart & 0xFFFF)
        } else {
            // U32: write integer value directly, HIGH=0, LOW=value
            raw32 = Int32(value.rounded())
        }
        let u32 = UInt32(bitPattern: raw32)
        let bytes: [UInt8] = [
            0x01, 0x10,
            UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF),   // address
            0x00, 0x02,                                     // number of registers = 2
            0x00,                                           // reserved (byte count placeholder — NOT standard; see note)
            UInt8((u32 >> 24) & 0xFF), UInt8((u32 >> 16) & 0xFF),  // HIGH register
            UInt8((u32 >>  8) & 0xFF), UInt8( u32        & 0xFF)   // LOW register
        ]
        // Standard Modbus 0x10 includes byte count before data. Per protocol doc example:
        // "01 10 02 E1 00 02 00 00 00 00 D4 8B" — byte count field is 0x00 at position [6].
        // This matches the doc which shows Data6=0 (reserved/bytecount=0 in their notation).
        let crc = crc16(bytes)
        return Data(bytes + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)])
    }

    static func parseParameterValues(from data: Data, expectedStart: Int? = nil) -> [Int: Double] {
        let b = [UInt8](data)
        guard b.count >= 5 else { return [:] }

        // Modbus read response: 01 03 byteCount <register bytes> CRClo CRChi
        // DUNEN function-code table: each 32-bit parameter = 2 × 16-bit Modbus registers.
        // Tuning parameters are plain integers (0/1 toggle, small unsigned values).
        // Decode as plain U32: value = (HIGH << 16) | LOW, then round to nearest integer.
        // We check both HIGH and LOW words — the toggle value (0 or 1) could be in either.
        // If HIGH==0 take LOW directly; if LOW==0 and HIGH is a small integer take HIGH.
        // This handles both storage layouts seen in DUNEN firmware.
        if b[0] == 0x01 && b[1] == 0x03 {
            let byteCount = Int(b[2])
            guard b.count >= 3 + byteCount else { return [:] }

            var result: [Int: Double] = [:]
            let start = expectedStart ?? 0
            var offset = 3

            for i in 0..<(byteCount / 4) {
                guard offset + 3 < b.count else { break }
                let highWord = Int(UInt16(b[offset]) << 8 | UInt16(b[offset + 1]))
                let lowWord  = Int(UInt16(b[offset + 2]) << 8 | UInt16(b[offset + 3]))
                // Prefer LOW word if it holds the value; fall back to HIGH word.
                // Both 0 → value is 0. HIGH non-zero and LOW zero → value is in HIGH.
                let value: Double
                if lowWord != 0 {
                    value = Double(lowWord)
                } else if highWord != 0 {
                    value = Double(highWord)
                } else {
                    value = 0
                }
                let address = start + i * 2
                result[address] = value
                offset += 4
            }
            return result
        }
        return [:]
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
