import Foundation
import CoreBluetooth
import Combine

struct DiscoveredBLEDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

final class DunenBLEManager: NSObject, ObservableObject {
    @Published var connectionStatus = "Bluetooth not ready"
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published var savedDevices: [SavedDevice] = []
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var isDemoMode = false
    @Published var connectedName: String?
    @Published var telemetry = Telemetry()
    @Published var history = TelemetryHistory()
    @Published var packetLog: [String] = []
    @Published var developerStatus = "Idle"
    @Published var demoThrottle: Double = 0.55
    @Published var demoBrake: Double = 0.0
    @Published var demoSelectedMode: RideMode = .xc
    @Published var demoSpeedKmh: Double = 0
    @Published var rideStats = RideStats()
    @Published var diagnosticEvents: [DiagnosticEvent] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private weak var tuningStore: TuningStore?
    private weak var settings: AppSettings?
    private var demoTimer: Timer?
    private var demoTick: Double = 0
    private var lastSpeedKmh: Double = 0
    private var lastVoltage: Double = 0
    private var zeroToFiftyRunning = false
    private var zeroToFiftyStart: Date?
    private var pollTimer: Timer?

    private let serviceFFE0 = CBUUID(string: "FFE0")
    private let characteristicFFE1 = CBUUID(string: "FFE1")

    override init() {
        super.init()
        loadSavedDevices()
        if let data = UserDefaults.standard.data(forKey: "diagnosticEvents"),
           let decoded = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) {
            diagnosticEvents = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "rideStats"),
           let decoded = try? JSONDecoder().decode(RideStats.self, from: data) {
            rideStats = decoded
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func attachTuningStore(_ store: TuningStore) {
        tuningStore = store
    }

    func attachSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        if enabled {
            isConnected = false
            connectedName = "Demo AP8F"
            connectionStatus = "Demo Mode"
            startDemoTimer()
        } else {
            stopDemoTimer()
            telemetry = Telemetry()
            history = TelemetryHistory()
            connectedName = nil
            connectionStatus = central.state == .poweredOn ? "Bluetooth ready" : connectionStatus
        }
    }

    func startScan() {
        setDemoMode(false)
        guard central.state == .poweredOn else {
            connectionStatus = "Bluetooth is not powered on"
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        connectionStatus = "Scanning for DUNEN / FFE0..."
        let scanSoundEnabled = settings?.startupSound ?? true
        Task { @MainActor in SoundManager.shared.playScanningSound(enabled: scanSoundEnabled) }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if self.isScanning {
                self.central.stopScan()
                self.isScanning = false
                self.connectionStatus = self.discoveredDevices.isEmpty ? "No DUNEN devices found" : "Scan finished"
            }
        }
    }

    func connect(to device: DiscoveredBLEDevice) {
        setDemoMode(false)
        central.stopScan()
        isScanning = false
        connectionStatus = "Connecting to \(device.name)..."
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
        rememberDevice(id: device.id, name: device.name, rssi: device.rssi)
    }

    func startRideRecording() {
        rideStats.reset()
        rideStats.isRecording = true
        rideStats.startedAt = Date()
        rideStats.batteryStartVoltage = telemetry.voltage > 0 ? telemetry.voltage : 84.0
        addDiagnostic(title: "Ride started", detail: "Recording trip statistics.", severity: "info")
    }

    func stopRideRecording() {
        rideStats.isRecording = false
        addDiagnostic(title: "Ride stopped", detail: "Trip saved in app memory.", severity: "info")
        saveRideStats()
    }

    func resetRideRecording() {
        rideStats.reset()
        addDiagnostic(title: "Ride reset", detail: "Current trip statistics cleared.", severity: "info")
    }

    func disconnect() {
        stopPollTimer()
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func readCurrentSettings() {
        guard let p = connectedPeripheral, let c = writeCharacteristic else {
            tuningStore?.statusText = "Not connected to writable FFE1 characteristic"
            return
        }
        tuningStore?.markReading()
        p.writeValue(DunenProtocol.readAllParametersFrame(), for: c, type: .withResponse)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.tuningStore?.didLoadFromController == false {
                self.tuningStore?.isReading = false
                self.tuningStore?.statusText = "Read request sent. Waiting for controller parameter response."
            }
        }
    }

    func writeChangedSettings(_ params: [TuningParameter]) {
        guard let p = connectedPeripheral, let c = writeCharacteristic else {
            tuningStore?.statusText = "Not connected to writable FFE1 characteristic"
            return
        }
        guard tuningStore?.didLoadFromController == true else {
            tuningStore?.statusText = "Read current settings first"
            return
        }

        tuningStore?.isWriting = true
        tuningStore?.saveBackup(reason: "before-write")
        var ids: [Int] = []

        for param in params {
            guard let value = param.pendingValue else { continue }
            p.writeValue(DunenProtocol.writeParameterFrame(id: param.id, value: value), for: c, type: .withResponse)
            ids.append(param.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.tuningStore?.confirmWritten(ids: ids)
        }
    }
    func liveActivityDebugStatus() { developerStatus = "Live Activity removed" }
    func forceLiveActivityRefresh() { developerStatus = "Live Activity removed" }


    func clearDiagnosticHistory() {
        diagnosticEvents.removeAll()
        saveDiagnosticEvents()
        developerStatus = "Diagnostic history cleared"
    }

    func applyDeveloperUpdateInterval() {
        startDemoTimer()
        if isConnected { startPollTimer() }
    }

    private func startPollTimer() {
        stopPollTimer()
        let interval = settings?.updateInterval.rawValue ?? 1.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in DispatchQueue.main.async { [weak self] in self?.developerStatus = "Update interval: \(interval)s" } }
            // keep this conservative: no automatic writes, only read telemetry/known settings request
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startDemoTimer() {
        stopDemoTimer()
        let interval = settings?.updateInterval.rawValue ?? 1.0
        demoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in DispatchQueue.main.async { [weak self] in self?.updateDemo() } }
        }
        demoTimer?.fire()
    }

    private func stopDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = nil
    }

    private func updateDemo() {
        demoTick += settings?.updateInterval.rawValue ?? 0.1
        let dt = settings?.updateInterval.rawValue ?? 0.1

        if settings?.demoAutoInput ?? true {
            demoThrottle = 0.48 + 0.34 * (sin(demoTick / 5.0) + 1.0) / 2.0
            demoBrake = max(0, sin(demoTick / 9.0) - 0.82) * 2.2
            let cycle = Int((demoTick / 18.0).truncatingRemainder(dividingBy: 3))
            demoSelectedMode = cycle == 0 ? .eco : (cycle == 1 ? .xc : .sports)
        }

        let mode = demoSelectedMode
        let maxSpeedForMode: Double = {
            switch mode {
            case .eco: return 45
            case .xc: return 75
            case .sports: return 105
            case .reverse: return 14
            case .park: return 0
            }
        }()

        let targetSpeed = max(0, maxSpeedForMode * demoThrottle * (1.0 - demoBrake))
        let smoothing = min(1.0, dt * (demoBrake > 0.05 ? 5.0 : 2.0))
        demoSpeedKmh += (targetSpeed - demoSpeedKmh) * smoothing

        let accelPulse = max(0, demoThrottle - demoBrake)
        let rpm = mode == .park ? 0 : Int(demoSpeedKmh * 82 + 650 + 250 * accelPulse)
        let voltage = 78.8 - min(demoTick / 1400.0, 4.0) - accelPulse * 0.25
        let rawCurrent = mode == .park ? 0 : max(0, demoSpeedKmh / 1.25 + demoThrottle * 48 - demoBrake * 10)
        let modePowerCapKw: Double = {
            switch mode {
            case .eco: return 4.2
            case .xc: return 6.5
            case .sports: return 10.0
            case .reverse: return 1.8
            case .park: return 0.0
            }
        }()
        let current = min(rawCurrent, max(0, modePowerCapKw * 1000 / max(voltage, 1)))

        telemetry.speedKmh = mode == .park ? 0 : demoSpeedKmh
        telemetry.rpm = rpm
        telemetry.voltage = voltage
        telemetry.currentA = current
        telemetry.odometerKm += telemetry.speedKmh / 3600.0 * dt
        telemetry.warningCode = telemetry.controllerTemp > 70 ? 1 : 0
        telemetry.errorCode = 0
        telemetry.phaseVoltage = voltage / 2.55
        telemetry.motorAngle = Int((demoTick * 180).truncatingRemainder(dividingBy: 3600))
        telemetry.torque = current / 3.2
        telemetry.zeroAngle = 2330
        telemetry.motorTemp = 33 + telemetry.speedKmh / 7 + current / 16
        telemetry.controllerTemp = 28 + current / 5.0
        telemetry.mode = mode
        telemetry.reverseActive = mode == .reverse
        telemetry.parkingActive = mode == .park
        telemetry.kickstandActive = mode == .park
        telemetry.brakeActive = demoBrake > 0.15
        telemetry.headlightActive = true
        telemetry.packetCount += 1
        telemetry.rawHex = "DE MO \(String(format: "%02X", Int(telemetry.speedKmh))) \(String(format: "%02X", rpm & 0xff))"

        calculateDerived(dt: dt)
        // keep lean smooth in demo; braking should not spike it full left/right
        let turnWave = sin(demoTick / 2.8) * min(1.0, telemetry.speedKmh / 45.0)
        telemetry.leanAngle = max(-22, min(22, turnWave * 12))
        if demoBrake > 0.2 {
            telemetry.leanAngle *= 0.45
        }

        history.append(telemetry)
        updateRideStats(dt: dt)
        checkDiagnosticEvents()
        
    }

    private func addPacket(_ data: Data) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        telemetry.rawHex = hex
        telemetry.packetCount += 1
        packetLog.insert(hex, at: 0)
        if packetLog.count > 80 { packetLog.removeLast() }

        decodeTelemetry(data)
        telemetry.currentA = max(0, telemetry.torque * 3.0)
        history.append(telemetry)

        let parsed = DunenProtocol.parseParameterValues(from: data)
        if !parsed.isEmpty { tuningStore?.applyReadValues(parsed) }
    }

    private func decodeTelemetry(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8 else { return }

        if b.count >= 12 {
            let vRaw = UInt16(b[2]) | (UInt16(b[3]) << 8)
            let rpmRaw = UInt16(b[4]) | (UInt16(b[5]) << 8)
            let speedRaw = UInt16(b[6]) | (UInt16(b[7]) << 8)
            let voltage = Double(vRaw) / 10.0
            if voltage > 20 && voltage < 120 { telemetry.voltage = voltage }
            let rpm = Int(rpmRaw)
            if rpm >= 0 && rpm < 22000 { telemetry.rpm = rpm }
            let speed = Double(speedRaw) / 10.0
            if speed >= 0 && speed < 190 { telemetry.speedKmh = speed }
        }

        if b.count > 15 {
            telemetry.warningCode = Int(b[8])
            telemetry.errorCode = Int(b[9])
            telemetry.phaseVoltage = Double(UInt16(b[10]) | (UInt16(b[11]) << 8)) / 100.0
            telemetry.motorAngle = Int(UInt16(b[12]) | (UInt16(b[13]) << 8))
            telemetry.motorTemp = Double(Int8(bitPattern: b[14]))
            telemetry.controllerTemp = Double(Int8(bitPattern: b[15]))
            telemetry.currentA = max(0, telemetry.torque * 3.0)
            telemetry.mode = telemetry.parkingActive ? .park : (telemetry.reverseActive ? .reverse : .xc)
            calculateDerived(dt: settings?.updateInterval.rawValue ?? 0.1)
        }
    }

    private func calculateDerived(dt: Double) {
        telemetry.powerKw = (telemetry.voltage * telemetry.currentA) / 1000.0
        telemetry.batteryPercent = min(100, max(0, (telemetry.voltage - 58.0) / (84.0 - 58.0) * 100.0))
        telemetry.voltageSag = max(0, lastVoltage - telemetry.voltage)
        let speedDeltaMs = ((telemetry.speedKmh - lastSpeedKmh) / 3.6) / max(dt, 0.05)
        telemetry.gForce = speedDeltaMs / 9.81
        telemetry.leanAngle = max(-42, min(42, telemetry.gForce * 28.0 + sin(demoTick / 2.6) * 6.0))
        let rearWheelCircumferenceM = 3.14159 * (18.0 * 0.0254)
        telemetry.wheelRPM = rearWheelCircumferenceM > 0 ? (telemetry.speedKmh * 1000.0 / 60.0) / rearWheelCircumferenceM : 0
        let estimatedRatio = 48.0 / 14.0
        telemetry.wheelTorqueNm = telemetry.torque * estimatedRatio * 0.88
        telemetry.theoreticalTopSpeedKmh = 136.0
        lastSpeedKmh = telemetry.speedKmh
        lastVoltage = telemetry.voltage
    }

    private func updateRideStats(dt: Double) {
        guard rideStats.isRecording else { return }
        rideStats.durationSeconds += dt
        rideStats.sampleCount += 1
        rideStats.tripKm += telemetry.speedKmh / 3600.0 * dt
        rideStats.topSpeedKmh = max(rideStats.topSpeedKmh, telemetry.speedKmh)
        rideStats.peakRPM = max(rideStats.peakRPM, telemetry.rpm)
        rideStats.peakCurrentA = max(rideStats.peakCurrentA, telemetry.currentA)
        rideStats.averageSpeedKmh = rideStats.sampleCount > 0 ? ((rideStats.averageSpeedKmh * Double(rideStats.sampleCount - 1)) + telemetry.speedKmh) / Double(rideStats.sampleCount) : telemetry.speedKmh
        if let start = rideStats.batteryStartVoltage {
            rideStats.batteryUsedVoltage = max(0, start - telemetry.voltage)
        }

        if !zeroToFiftyRunning && telemetry.speedKmh < 2 {
            zeroToFiftyRunning = true
            zeroToFiftyStart = Date()
        }
        if zeroToFiftyRunning && telemetry.speedKmh >= 50, rideStats.zeroToFiftySeconds == nil {
            rideStats.zeroToFiftySeconds = Date().timeIntervalSince(zeroToFiftyStart ?? Date())
            zeroToFiftyRunning = false
            addDiagnostic(title: "0–50 km/h recorded", detail: String(format: "%.2f seconds", rideStats.zeroToFiftySeconds ?? 0), severity: "info")
        }
    }

    private func checkDiagnosticEvents() {
        if telemetry.warningCode != 0 {
            addDiagnostic(title: "Warning code \(telemetry.warningCode)", detail: "Controller warning detected.", severity: "warning")
        }
        if telemetry.errorCode != 0 {
            addDiagnostic(title: "Error code \(telemetry.errorCode)", detail: "Controller error detected.", severity: "error")
        }
        if telemetry.controllerTemp > 75 {
            addDiagnostic(title: "Controller hot", detail: String(format: "%.0f °C", telemetry.controllerTemp), severity: "warning")
        }
        if telemetry.voltageSag > 1.8 {
            addDiagnostic(title: "Voltage sag", detail: String(format: "%.2f V drop", telemetry.voltageSag), severity: "warning")
        }
    }

    private func addDiagnostic(title: String, detail: String, severity: String) {
        guard diagnosticEvents.first?.title != title || diagnosticEvents.first?.detail != detail else { return }
        diagnosticEvents.insert(DiagnosticEvent(date: Date(), title: title, detail: detail, severity: severity), at: 0)
        if diagnosticEvents.count > 60 { diagnosticEvents.removeLast() }
        saveDiagnosticEvents()
    }

    private func saveRideStats() {
        guard let data = try? JSONEncoder().encode(rideStats) else { return }
        UserDefaults.standard.set(data, forKey: "rideStats")
    }

    private func saveDiagnosticEvents() {
        guard let data = try? JSONEncoder().encode(diagnosticEvents) else { return }
        UserDefaults.standard.set(data, forKey: "diagnosticEvents")
    }
    private func updateLiveActivityIfNeeded() {
        // Live Activity removed
    }


    private func shouldShowDevice(name: String, advertisementData: [String: Any]) -> Bool {
        if name.uppercased().contains("DUNEN") { return true }
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            return uuids.contains(serviceFFE0)
        }
        return false
    }

    private func rememberDevice(id: UUID, name: String, rssi: Int) {
        let saved = SavedDevice(id: id, name: name, lastRSSI: rssi, lastSeen: Date())
        savedDevices.removeAll { $0.id == id }
        savedDevices.insert(saved, at: 0)
        if savedDevices.count > 8 { savedDevices.removeLast() }
        saveSavedDevices()
    }

    private func loadSavedDevices() {
        guard let data = UserDefaults.standard.data(forKey: "savedDevices"),
              let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return }
        savedDevices = decoded
    }

    private func saveSavedDevices() {
        guard let data = try? JSONEncoder().encode(savedDevices) else { return }
        UserDefaults.standard.set(data, forKey: "savedDevices")
    }
}

extension DunenBLEManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectionStatus = "Bluetooth ready"
        case .poweredOff: connectionStatus = "Bluetooth off"
        case .unauthorized: connectionStatus = "Bluetooth permission denied"
        case .unsupported: connectionStatus = "Bluetooth not supported"
        default: connectionStatus = "Bluetooth state: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        guard shouldShowDevice(name: name, advertisementData: advertisementData) else { return }

        let device = DiscoveredBLEDevice(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
        }
        rememberDevice(id: device.id, name: device.name, rssi: device.rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        isDemoMode = false
        connectedName = peripheral.name ?? "DUNEN"
        connectionStatus = "Connected. Discovering services..."
        let connectSoundEnabled = settings?.startupSound ?? true
        Task { @MainActor in SoundManager.shared.playConnectSound(enabled: connectSoundEnabled) }
        peripheral.discoverServices([serviceFFE0])
        startPollTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectionStatus = "Failed to connect: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedName = nil
        connectedPeripheral = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        stopPollTimer()
        connectionStatus = "Disconnected"
    }
}

extension DunenBLEManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionStatus = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            connectionStatus = "No services found"
            return
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        connectionStatus = "Discovering characteristics..."
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            connectionStatus = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }
        guard let chars = service.characteristics else { return }

        for ch in chars {
            if ch.uuid == characteristicFFE1 || ch.properties.contains(.notify) {
                notifyCharacteristic = ch
                peripheral.setNotifyValue(true, for: ch)
            }
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = ch
            }
            if ch.properties.contains(.read) { peripheral.readValue(for: ch) }
        }

        if writeCharacteristic == nil { writeCharacteristic = notifyCharacteristic }
        connectionStatus = "Ready. Press Read Current Settings before tuning."
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            connectionStatus = "Read/notify error: \(error.localizedDescription)"
            return
        }
        guard let data = characteristic.value else { return }
        addPacket(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            tuningStore?.statusText = "Write error: \(error.localizedDescription)"
        } else {
            tuningStore?.statusText = "Controller acknowledged write"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            connectionStatus = "Notify failed: \(error.localizedDescription)"
            return
        }
        if characteristic.isNotifying { connectionStatus = "Receiving live packets" }
    }
}
