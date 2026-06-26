import Foundation
import CoreBluetooth
import Combine

final class AppLogManager: ObservableObject {
    static let shared = AppLogManager()

    @Published private(set) var latestLines: [String] = []

    private let writerQueue = DispatchQueue(label: "aptum.dashboard.log.writer")
    private let uiQueue = DispatchQueue.main
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var logURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AptumDashboard_BLE_Log.txt")
    }

    var jsonURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AptumDashboard_BLE_Log.jsonl")
    }

    func log(_ category: String, _ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)"

        uiQueue.async { [weak self] in
            guard let self else { return }
            self.latestLines.insert(line, at: 0)
            if self.latestLines.count > 120 { self.latestLines.removeLast() }
        }

        let txtURL = logURL
        let jsURL = jsonURL
        writerQueue.async {
            Self.append(line + "\n", to: txtURL)

            let json: [String: Any] = [
                "time": timestamp,
                "category": category,
                "message": message
            ]

            if let data = try? JSONSerialization.data(withJSONObject: json),
               let str = String(data: data, encoding: .utf8) {
                Self.append(str + "\n", to: jsURL)
            }
        }
    }

    func logPacket(_ direction: String, characteristic: CBCharacteristic?, data: Data, note: String = "") {
        let uuid = characteristic?.uuid.uuidString ?? "unknown"
        let props = characteristic.map { Self.propertiesString($0.properties) } ?? "unknown"
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        log("BLE-\(direction)", "\(uuid) \(props) len=\(data.count) \(note) hex=\(hex)")
    }

    func logDecoded(_ values: [Int: Double], source: String) {
        guard !values.isEmpty else {
            log("DECODE", "\(source) no values decoded")
            return
        }

        let preview = values.keys.sorted().prefix(40).map { key in
            "\(key)=\(String(format: "%.4f", values[key] ?? 0))"
        }.joined(separator: ", ")

        log("DECODE", "\(source) \(preview)")
    }

    func clear() {
        let txtURL = logURL
        let jsURL = jsonURL

        uiQueue.async { [weak self] in
            self?.latestLines.removeAll()
        }

        writerQueue.async {
            try? FileManager.default.removeItem(at: txtURL)
            try? FileManager.default.removeItem(at: jsURL)
            Self.append("[\(ISO8601DateFormatter().string(from: Date()))] [APP] Log cleared\n", to: txtURL)
        }
    }

    static func propertiesString(_ props: CBCharacteristicProperties) -> String {
        var items: [String] = []
        if props.contains(.read) { items.append("read") }
        if props.contains(.write) { items.append("write") }
        if props.contains(.writeWithoutResponse) { items.append("writeNoRsp") }
        if props.contains(.notify) { items.append("notify") }
        if props.contains(.indicate) { items.append("indicate") }
        return items.joined(separator: "|")
    }

    private static func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never crash the app.
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
