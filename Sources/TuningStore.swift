import Foundation

final class TuningStore: ObservableObject {
    @Published var parameters: [TuningParameter] = TuningParameter.defaults
    @Published var didLoadFromController: Bool = false
    @Published var isReading: Bool = false
    @Published var isWriting: Bool = false
    @Published var lastBackupURL: URL?
    @Published var statusText: String = "Connect and press Read Current Settings"

    var changedParameters: [TuningParameter] {
        parameters.filter { $0.hasChange }
    }

    func markReading() {
        isReading = true
        statusText = "Reading controller settings..."
    }

    func applyReadValues(_ values: [Int: Double]) {
        for idx in parameters.indices {
            if let value = values[parameters[idx].id] {
                parameters[idx].currentValue = value
                parameters[idx].originalValue = parameters[idx].originalValue ?? value
                parameters[idx].pendingValue = value
            }
        }
        didLoadFromController = parameters.contains { $0.loaded }
        isReading = false
        statusText = didLoadFromController ? "Loaded current settings" : "No known tuning params found in packet yet"
        if didLoadFromController { saveBackup(reason: "manual") }
    }

    func updatePending(id: Int, value: Double) {
        guard let idx = parameters.firstIndex(where: { $0.id == id }) else { return }
        parameters[idx].pendingValue = min(max(value, parameters[idx].min), parameters[idx].max)
    }

    /// Like updatePending but also enforces monotonicity for throttle curve sliders:
    /// points before `id` are clamped to ≤ newValue; points after are clamped to ≥ newValue.
    func updatePendingMonotone(id: Int, value: Double) {
        guard let idx = parameters.firstIndex(where: { $0.id == id }) else {
            updatePending(id: id, value: value)
            return
        }
        // Only apply monotone logic to throttle curve parameters
        let isThrottle = parameters[idx].group == .throttle && parameters[idx].kind == .slider
        guard isThrottle else {
            updatePending(id: id, value: value)
            return
        }

        let clamped = min(max(value, parameters[idx].min), parameters[idx].max)
        parameters[idx].pendingValue = clamped

        // Clamp preceding points to ≤ clamped
        for i in 0..<idx where parameters[i].group == .throttle && parameters[i].kind == .slider {
            let prev = parameters[i].pendingValue ?? parameters[i].currentValue ?? 0
            if prev > clamped { parameters[i].pendingValue = clamped }
        }
        // Clamp following points to ≥ clamped
        for i in (idx + 1)..<parameters.count where parameters[i].group == .throttle && parameters[i].kind == .slider {
            let next = parameters[i].pendingValue ?? parameters[i].currentValue ?? 0
            if next < clamped { parameters[i].pendingValue = clamped }
        }
    }

    func confirmWritten(ids: [Int]) {
        for idx in parameters.indices {
            if ids.contains(parameters[idx].id), let pending = parameters[idx].pendingValue {
                parameters[idx].currentValue = pending
            }
        }
        isWriting = false
        statusText = "Write completed"
        saveBackup(reason: "after-write")
    }

    func saveBackup(reason: String) {
        if reason == "auto-read" { return }

        let backup = TuningBackup(date: Date(), reason: reason, parameters: parameters)
        do {
            let data = try JSONEncoder.pretty.encode(backup)
            let url = documentsDirectory().appendingPathComponent("aptum-settings-backup-manual-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url)
            lastBackupURL = url
        } catch {
            statusText = "Backup failed: \(error.localizedDescription)"
        }
    }

    func loadLocalBackup() {
        let dir = documentsDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let backups = files.filter { $0.lastPathComponent.hasPrefix("aptum-settings-backup") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let latest = backups.first,
              let data = try? Data(contentsOf: latest),
              let backup = try? JSONDecoder().decode(TuningBackup.self, from: data) else { return }
        parameters = backup.parameters
        lastBackupURL = latest
        statusText = "Loaded local backup"
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}

struct TuningBackup: Codable {
    var date: Date
    var reason: String
    var parameters: [TuningParameter]
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
