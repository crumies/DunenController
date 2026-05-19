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
        if didLoadFromController { saveBackup(reason: "auto-read") }
    }

    func updatePending(id: Int, value: Double) {
        guard let idx = parameters.firstIndex(where: { $0.id == id }) else { return }
        parameters[idx].pendingValue = min(max(value, parameters[idx].min), parameters[idx].max)
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
        let backup = TuningBackup(date: Date(), reason: reason, parameters: parameters)
        do {
            let data = try JSONEncoder.pretty.encode(backup)
            let url = documentsDirectory().appendingPathComponent("aptum-settings-backup-\(Int(Date().timeIntervalSince1970)).json")
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
