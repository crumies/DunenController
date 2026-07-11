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
    private var secondaryWriteCharacteristic: CBCharacteristic?
    private weak var tuningStore: TuningStore?
    private weak var settings: AppSettings?
    private var demoTimer: Timer?
    private var demoTick: Double = 0
    private var pollFrames: [(start: Int, data: Data)] = []
    private var pollIndex: Int = 0
    private var pendingReadStarts: [Int] = []
    private var inFlightReadStart: Int?
    private var inFlightSentAt: Date?
    private var lastDecodedStart: Int?
    private var bootScanDone: Bool = false
    private var didSendLiveEnable: Bool = false
    private var lastLiveNotifyAt: Date?
    private var lastStableRideMode: RideMode = .eco
    private var lastLiveFlags: Int = 0
    private var modeStaticReadStep: Int = 0
    private var lastModeStaticReadAt: Date?
    private var liveProbeTick: Int = 0
    private var lastSpeedKmh: Double = 0
    private var lastVoltage: Double = 0
    private var zeroToFiftyRunning = false
    private var zeroToFiftyStart: Date?
    private var pollTimer: Timer?

    private let serviceFFE0 = CBUUID(string: "FFE0")
    private let characteristicFFE1 = CBUUID(string: "FFE1")
    private let characteristicFFF2 = CBUUID(string: "FFF2")
    private let appLogger = AppLogManager.shared

    // DUNEN controller TYPE shown by the official app.
    // Used for cloud/default/read attempts and for logs.
    private let dunenControllerTypeString = "DEMCC2416QS035ZFS01"
    private var lastRawDisplaySpeed: Double = 0
    private var lastRawMotorCount: Int = 0

    // AP8F gearing from user: 48T rear, 15T front, 18 inch rear wheel.
    private let frontSprocketTeeth: Double = 15.0
    private let rearSprocketTeeth: Double = 48.0
    private let rearWheelDiameterInches: Double = 18.0
    private var finalDriveRatio: Double { rearSprocketTeeth / frontSprocketTeeth }
    private var rearWheelCircumferenceM: Double { Double.pi * rearWheelDiameterInches * 0.0254 }
    private var kmhPerMotorRPM: Double { rearWheelCircumferenceM * 60.0 / 1000.0 / finalDriveRatio }
    private var motorRPMPerKmh: Double { kmhPerMotorRPM > 0 ? 1.0 / kmhPerMotorRPM : 0.0 }

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
        appLogger.log("APP", "DunenBLEManager initialized")
    }

    func attachTuningStore(_ store: TuningStore) {
        tuningStore = store
    }

    func attachSettings(_ settings: AppSettings) {
        self.settings = settings
    }

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        appLogger.log("APP", "Demo mode set to \(enabled)")
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
        appLogger.log("BLE", "Scan stopped")
        isScanning = false
        connectionStatus = "Connecting to \(device.name)..."
        appLogger.log("BLE", "Connecting to \(device.name) id=\(device.id.uuidString)")
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
            tuningStore?.statusText = "Not connected to writable FFF2 characteristic"
            return
        }
        tuningStore?.markReading()
        pendingReadStarts.append(99)
        p.writeValue(DunenProtocol.modbusReadFrame(start: 97, count: 24), for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak p, weak c] in
            guard let self, let p, let c else { return }
            self.pendingReadStarts.append(211)
            p.writeValue(DunenProtocol.modbusReadFrame(start: 209, count: 24), for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.tuningStore?.didLoadFromController == false {
                self.tuningStore?.isReading = false
                self.tuningStore?.statusText = "Read request sent. Waiting for controller parameter response."
            }
        }
    }

    func writeChangedSettings(_ params: [TuningParameter]) {
        guard let p = connectedPeripheral, let c = writeCharacteristic else {
            tuningStore?.statusText = "Not connected to writable FFF2 characteristic"
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
            let frame = DunenProtocol.writeParameterFrame(id: param.id, value: value)
            appLogger.logPacket("TX-WRITE", characteristic: c, data: frame, note: "MANUAL TUNING WRITE id=\(param.id) value=\(value)")
            p.writeValue(frame, for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
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
        pendingReadStarts.removeAll()
        inFlightReadStart = nil
        inFlightSentAt = nil
        lastDecodedStart = nil
        bootScanDone = true
        didSendLiveEnable = false
        didSendDunenTypeReads = false
        lastLiveNotifyAt = nil
        pollIndex = 0
        liveProbeTick = 0
        outputPollIdx = 0

        // Build 105:
        // DUNEN does NOT continuously show the live values just from normal table reads.
        // The official app enables AC/live debug using a 0x10 write to 0x03E8, then the
        // controller pushes live 0x03/0x30 notifications. We now do the same and parse
        // live notifications by shape, not only by pending request start.
        pollFrames = [
            (0x0418, DunenProtocol.modbusReadFrame(start: 0x0418, count: 0x0002)),
            (0x0400, DunenProtocol.modbusReadFrame(start: 0x0400, count: 0x0018))
        ]

        let interval = 0.35
        appLogger.log("POLL", "Starting Build105 LIVE NOTIFY ENABLE interval=\(interval)s")

        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.requestLiveOutput()
            }
        }
        pollTimer?.fire()
    }

    private var didSendDunenTypeReads: Bool = false

    private func sendDunenTypeAndDefaultReadsIfNeeded() {
        guard !didSendDunenTypeReads, isConnected, let p = connectedPeripheral else { return }
        guard let c = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic else { return }
        didSendDunenTypeReads = true

        // The official DUNEN app asks for TYPE before some default/read operations.
        // We send it as plain ASCII and also log it, then do harmless read probes.
        let typeData = Data(dunenControllerTypeString.utf8)
        let writeType: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.appLogger.logPacket("TX", characteristic: c, data: typeData, note: "DUNEN TYPE \(self.dunenControllerTypeString)")
            p.writeValue(typeData, for: c, type: writeType)
        }

        // Low-risk probes the DUNEN app commonly does for model/version/default values.
        let probes = [
            DunenProtocol.modbusReadFrame(start: 0xFFEE, count: 0x0002),
            DunenProtocol.modbusReadFrame(start: 0xFFED, count: 0x0002),
            DunenProtocol.modbusReadFrame(start: 0xFFEC, count: 0x0010)
        ]

        for (idx, frame) in probes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20 + Double(idx) * 0.15) {
                self.appLogger.logPacket("TX", characteristic: c, data: frame, note: "DUNEN type/default probe \(idx)")
                p.writeValue(frame, for: c, type: writeType)
            }
        }
    }

    private func sendDunenLiveEnableIfNeeded(force: Bool = false) {
        guard isConnected, let p = connectedPeripheral else { return }
        guard let c = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic else { return }

        if didSendLiveEnable && !force { return }

        didSendLiveEnable = true

        // Same command seen in the official DUNEN injected log:
        // 01 10 03 E8 00 12 24 [36 zero bytes] CRC
        let enableHex = "01 10 03 E8 00 12 24 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 53 69"
        let data = Data(enableHex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        appLogger.logPacket("TX", characteristic: c, data: data, note: "DUNEN live notify enable 0x03E8")
        p.writeValue(data, for: c, type: type)
    }

    private func isDunenLive0400Frame(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 53, b[0] == 0x01, b[1] == 0x03, b[2] == 0x30 else { return false }

        func u16(_ index: Int) -> Int {
            let o = 3 + index * 2
            guard o + 1 < b.count else { return 0 }
            return Int(UInt16(b[o]) << 8 | UInt16(b[o + 1]))
        }

        func fixed(_ frac: Int, _ whole: Int) -> Double {
            Double(Int16(bitPattern: UInt16(u16(whole)))) + Double(u16(frac)) / 65536.0
        }

        let voltage = fixed(2, 3)
        let speed = fixed(4, 5)
        let controllerT = fixed(6, 7)
        let motorT = fixed(8, 9)

        // Real live frames from DUNEN look like:
        // voltage 70-90, speed 0-160, controller temp 5-120, motor temp 5-120.
        return voltage >= 45 && voltage <= 95 &&
               speed >= 0 && speed <= 160 &&
               controllerT >= 5 && controllerT <= 120 &&
               motorT >= 5 && motorT <= 120
    }

    private func looksLikeBogusPatternPage(_ regs: [Int]) -> Bool {
        guard regs.count >= 8 else { return false }

        // The log shows these are NOT real gear/mode tables:
        // 0x122: 0,4,0,8,0,12...
        // 0x13A: 0,52,0,56,0,60...
        // 0x152: 38666,0,43254,0... then many 0/1
        let zeroEveryOther = stride(from: 0, to: min(regs.count, 12), by: 2).allSatisfy { regs[$0] == 0 }
        let risingEveryOther = stride(from: 1, to: min(regs.count, 12), by: 2).map { regs[$0] }
        let isSimpleRising = risingEveryOther.count >= 4 && zip(risingEveryOther, risingEveryOther.dropFirst()).allSatisfy { $1 > $0 && ($1 - $0) <= 8 }

        if zeroEveryOther && isSimpleRising { return true }

        let highAlternating = regs.prefix(12).enumerated().allSatisfy { idx, val in
            idx % 2 == 0 ? val > 30000 : val == 0
        }
        if highAlternating { return true }

        return false
    }

    private func resolveGearAndRideMode() {
        // Gear and ride mode are separate.
        // Only force P/R from sane gear values. Ignore impossible pattern values.
        let saneGear = [0, 2, 4].contains(telemetry.gearRaw) || [0, 2, 4].contains(telemetry.gearInputRaw)

        if saneGear && (telemetry.gearRaw == 4 || telemetry.gearInputRaw == 4 || telemetry.reverseActive) {
            telemetry.mode = .reverse
            telemetry.reverseActive = true
            telemetry.parkingActive = false
            return
        }

        if saneGear && (telemetry.gearRaw == 0 || telemetry.gearInputRaw == 0 || telemetry.parkingActive) {
            if telemetry.speedKmh <= 0.3 && telemetry.rpm <= 5 {
                telemetry.mode = .park
                telemetry.parkingActive = true
                telemetry.reverseActive = false
                return
            }
        }

        telemetry.parkingActive = false
        telemetry.reverseActive = false

        switch telemetry.speedModeRaw {
        case 0:
            telemetry.mode = .eco
            lastStableRideMode = .eco
        case 1:
            telemetry.mode = .xc
            lastStableRideMode = .xc
        case 2:
            telemetry.mode = .sports
            lastStableRideMode = .sports
        default:
            telemetry.mode = lastStableRideMode
        }
    }

    // Output register blocks polled in round-robin every N live ticks.
    // 266=current, 314=torque, 338=voltage/5V/15V, 362=vehicle speed.
    private let outputPollStarts = [266, 314, 338, 362]
    private var outputPollIdx = 0

    private func requestLiveOutput() {
        guard isConnected, let p = connectedPeripheral else { return }

        sendDunenTypeAndDefaultReadsIfNeeded()
        sendDunenLiveEnableIfNeeded()

        if let last = lastLiveNotifyAt, Date().timeIntervalSince(last) > 2.5 {
            appLogger.log("POLL", "No live notify for >2.5s, re-enabling")
            didSendLiveEnable = false
            sendDunenLiveEnableIfNeeded(force: true)
        }

        if let start = inFlightReadStart {
            let age = Date().timeIntervalSince(inFlightSentAt ?? Date())
            if age < 0.45 { return }
            appLogger.log("POLL-TIMEOUT", "Dropping in-flight start=0x\(String(start, radix: 16))")
            inFlightReadStart = nil
            inFlightSentAt = nil
        }

        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic

        // Every 4 ticks poll one output register block in round-robin (voltage, speed, current, torque).
        if liveProbeTick % 4 == 0 {
            let start = outputPollStarts[outputPollIdx % outputPollStarts.count]
            outputPollIdx += 1
            let frame = DunenProtocol.modbusReadFrame(start: start, count: 24)
            inFlightReadStart = start
            inFlightSentAt = Date()
            developerStatus = "Polling reg \(start)"
            sendReadOnlyFrame(frame, via: target, peripheral: p, note: "output-block start=\(start)")
        } else {
            // Main live dashboard frame.
            let frame = DunenProtocol.modbusReadFrame(start: 0x0400, count: 0x0018)
            inFlightReadStart = 0x0400
            inFlightSentAt = Date()
            developerStatus = "Live 0x0400 polling"
            sendReadOnlyFrame(frame, via: target, peripheral: p, note: "live-only start=0x400")
        }
        liveProbeTick += 1
    }

    private func sendReadOnlyFrame(_ data: Data, via characteristic: CBCharacteristic?, peripheral: CBPeripheral, note: String = "readOnly") {
        guard let c = characteristic else { return }
        guard c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        appLogger.logPacket("TX", characteristic: c, data: data, note: "type=\(type == .withoutResponse ? "withoutResponse" : "withResponse") \(note)")
        peripheral.writeValue(data, for: c, type: type)
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
            case .eco: return 68
            case .xc: return 102
            case .sports: return 136
            case .reverse: return 6
            case .park: return 0
            }
        }()

        let targetSpeed = max(0, maxSpeedForMode * demoThrottle * (1.0 - demoBrake))
        let smoothing = min(1.0, dt * (demoBrake > 0.05 ? 5.0 : 2.0))
        demoSpeedKmh += (targetSpeed - demoSpeedKmh) * smoothing

        let accelPulse = max(0, demoThrottle - demoBrake)
        let rpmRaw = mode == .park ? 0 : Int(telemetry.speedKmh * 8000.0 / 136.0)
        let rpmLimitForMode: Int = {
            switch mode {
            case .eco: return 4000
            case .xc: return 6000
            case .sports: return 8000
            case .reverse: return 260
            case .park: return 0
            }
        }()
        let rpm = min(max(0, rpmRaw), rpmLimitForMode)
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
        appLogger.logPacket("RX", characteristic: notifyCharacteristic, data: data)

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        telemetry.rawHex = hex
        telemetry.packetCount += 1
        packetLog.insert(hex, at: 0)
        if packetLog.count > 80 { packetLog.removeLast() }

        if data.allSatisfy({ $0 == 0 }) {
            appLogger.log("RX-IGNORED", "zero/empty packet len=\(data.count)")
            return
        }

        if data.count >= 4 && data[0] == 0x01 && data[1] == 0x10 {
            appLogger.log("RX-ACK", "write ack len=\(data.count) hex=\(hex)")
            return
        }

        let isModbusRead = data.count >= 3 && data[0] == 0x01 && data[1] == 0x03

        // Build114 robust live decode: 0x0400 can arrive as response or notification.
        if isDunenLive0400Frame(data) {
            lastLiveNotifyAt = Date()
            inFlightReadStart = nil
            inFlightSentAt = nil
            appLogger.log("PARSER", "Build114 robust live decode 0x400 len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: 0x0400)
            return
        }


        // Important: DUNEN live frames arrive as notifications and do not include
        // the start register. Detect them by shape and decode as 0x0400.
        if isDunenLive0400Frame(data) {
            lastLiveNotifyAt = Date()
            if inFlightReadStart == 0x0400 { inFlightReadStart = nil; inFlightSentAt = nil }
            appLogger.log("PARSER", "liveNotify matchedStart=0x400 len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: 0x0400)
            return
        }

        if isModbusRead {
            guard let expectedStart = inFlightReadStart else {
                appLogger.log("RX-UNMATCHED", "0x03 response with no in-flight request len=\(data.count) hex=\(hex)")
                return
            }

            inFlightReadStart = nil
            inFlightSentAt = nil
            lastDecodedStart = expectedStart

            appLogger.log("PARSER", "matchedStart=0x\(String(expectedStart, radix: 16)) len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: expectedStart)
            return
        }

        decodeGenericFrame(data)
    }

    private func decodeDunenPage(_ data: Data, expectedStart: Int) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] == 0x01, b[1] == 0x03 else { return false }

        let byteCount = Int(b[2])
        guard b.count >= 3 + byteCount else { return false }

        func u16(_ index: Int) -> Int {
            let o = 3 + index * 2
            guard o + 1 < b.count else { return 0 }
            return Int(UInt16(b[o]) << 8 | UInt16(b[o + 1]))
        }

        func s16(_ index: Int) -> Int {
            Int(Int16(bitPattern: UInt16(u16(index))))
        }

        func fixedIntFrac(_ fracIndex: Int, _ intIndex: Int) -> Double {
            // DUNEN live 0x0400 uses: low word = fractional / 65536, next word = integer.
            // Example from real DUNEN log:
            // reg1026=66 reg1027=80 => ~80.001V
            // reg1030=41759 reg1031=30 => ~30.637C
            Double(s16(intIndex)) + (Double(u16(fracIndex)) / 65536.0)
        }

        var regs: [Int] = []
        for i in 0..<(byteCount / 2) {
            regs.append(u16(i))
        }

        appLogger.log("DUNEN-PAGE", "matchedStart=0x\(String(expectedStart, radix: 16)) regs=" + regs.enumerated().map { "\(expectedStart + $0.offset)=\($0.element)" }.joined(separator: ","))

        switch expectedStart {
        case 0x0400:
            // REAL live dashboard notification.
            //
            // reg1026 is live flags:
            // ECO=2, XC=10, SPORT=18, brake adds 64, park=0x01, reverse=0x04.
            let liveFlags = u16(2)
            lastLiveFlags = liveFlags

            let voltage = fixedIntFrac(2, 3)
            if voltage >= 45 && voltage <= 95 {
                // Keep decimals. Do not round.
                telemetry.voltage = (voltage * 100.0).rounded() / 100.0
                // voltage-to-SOC for 20s 72V (nominal 84V full, ~60V empty):
                // full = 84V = 100%, empty = 60V = 0%
                let soc = ((telemetry.voltage - 60.0) / (84.0 - 60.0)) * 100.0
                telemetry.batteryPercent = min(100, max(0, soc.rounded()))
                telemetry.bmsSoc = telemetry.batteryPercent
            }

            let controllerT = fixedIntFrac(6, 7)
            if controllerT >= 5 && controllerT <= 120 {
                telemetry.controllerTemp = floor(controllerT)
            }

            let motorT = fixedIntFrac(8, 9)
            if motorT >= 5 && motorT <= 120 {
                telemetry.motorTemp = floor(motorT)
            }

            let rawMotor = abs(s16(18))
            lastRawMotorCount = rawMotor
            telemetry.motorAngle = rawMotor
            telemetry.zeroAngle = u16(20)

            // Throttle/brake state from flags.
            telemetry.brakeActive = (liveFlags & 0x40) != 0

            // Park / Reverse from live flags (bits 0x01 = park, 0x04 = reverse).
            if (liveFlags & 0x04) != 0 {
                telemetry.mode = .reverse
                telemetry.reverseActive = true
                telemetry.parkingActive = false
                lastStableRideMode = .reverse
            } else if (liveFlags & 0x01) != 0 {
                telemetry.mode = .park
                telemetry.parkingActive = true
                telemetry.reverseActive = false
            } else if (liveFlags & 0x10) != 0 {
                telemetry.mode = .sports
                telemetry.speedModeRaw = 2
                telemetry.parkingActive = false
                telemetry.reverseActive = false
                lastStableRideMode = .sports
            } else if (liveFlags & 0x08) != 0 {
                telemetry.mode = .xc
                telemetry.speedModeRaw = 1
                telemetry.parkingActive = false
                telemetry.reverseActive = false
                lastStableRideMode = .xc
            } else {
                telemetry.mode = .eco
                telemetry.speedModeRaw = 0
                telemetry.parkingActive = false
                telemetry.reverseActive = false
                lastStableRideMode = .eco
            }

            // There is no lean sensor confirmed in this frame.
            telemetry.leanAngle = 0
            // Speed and RPM are updated from OVechSpd (reg 362) poll — not derived here.
            // Keep throttle open estimate based on whatever speed is already set.
            telemetry.throttleOpen = telemetry.speedKmh <= 0.3 ? 0 : min(1.0, telemetry.speedKmh / 60.0)

        case 338:
            // Block 338–361: OVkey (343), OVMon5V (344), OVMon15V (345)
            // Reg 343 = index 5, 344 = index 6, 345 = index 7 within this block.
            let keyVoltage = Double(regs[safe: 5] ?? 0) / 100.0
            if keyVoltage >= 45 && keyVoltage <= 95 {
                telemetry.voltage = (keyVoltage * 100.0).rounded() / 100.0
                let soc = ((telemetry.voltage - 60.0) / (84.0 - 60.0)) * 100.0
                telemetry.batteryPercent = min(100, max(0, soc.rounded()))
                telemetry.bmsSoc = telemetry.batteryPercent
            } else if telemetry.voltage == 0 {
                // voltage not yet set from live frame; keep whatever we have
            }
            let mon5v = Double(regs[safe: 6] ?? 0) / 100.0
            if mon5v > 0 { telemetry.internal5V = mon5v }
            let mon15v = Double(regs[safe: 7] ?? 0) / 100.0
            if mon15v > 0 { telemetry.internal15V = mon15v }

        case 266:
            // Block 266–289: IADin9 (282) = current, index = 282 - 266 = 16
            let currentRaw = Double(Int16(bitPattern: UInt16(regs[safe: 16] ?? 0))) / 100.0
            if currentRaw >= 0 { telemetry.currentA = currentRaw }

        case 314:
            // Block 314–337: OTorq (321), index = 321 - 314 = 7
            // Scale: example 1.8020 => raw = 18020, stored as single u16 * 10000
            let torqRaw = regs[safe: 7] ?? 0
            let torq = Double(torqRaw) / 10000.0
            if torq >= 0 && torq < 500 { telemetry.torque = torq }

        case 362:
            // Block 362–385: OVechSpd (362) = vehicle speed, index 0
            // raw / 100.0 = km/h
            let vechSpd = Double(regs[safe: 0] ?? 0) / 100.0
            if vechSpd >= 0 && vechSpd <= 200 {
                telemetry.speedKmh = vechSpd < 0.3 ? 0 : (vechSpd * 10.0).rounded() / 10.0
                if telemetry.speedKmh <= 0.3 {
                    telemetry.rpm = 0
                    telemetry.wheelRPM = 0
                } else {
                    telemetry.rpm = Int(round(telemetry.speedKmh * motorRPMPerKmh))
                    telemetry.wheelRPM = Double(telemetry.rpm) / finalDriveRatio
                }
            }

        case 0x0122:
            appLogger.log("MODEMAP", "0x0122 ignored; live flags control mode")

        case 0x013A:
            appLogger.log("MODEMAP", "0x013A ignored; live flags control mode")

        case 0x0152:
            appLogger.log("MODEMAP", "0x0152 ignored; live flags control mode")

        case 0x03E8:
            // Heartbeat/empty live page, keep only warnings/errors if present.
            if regs.count > 1 {
                telemetry.warningCode = u16(0)
                telemetry.errorCode = u16(1)
            }

        case 0x0418:
            if regs.count > 1 {
                telemetry.warningCode = u16(0)
                telemetry.errorCode = u16(1)
            }

        default:
            // Legacy blocks are ignored in Build104. They are engineering/config tables,
            // not the page the DUNEN dashboard uses for visible live values.
            break
        }

        telemetry.rawHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        telemetry.packetCount += 1

        calculateDerived(dt: 0.20)
        updateRideStats(dt: 0.20)
        checkDiagnosticEvents()

        appLogger.log("DISPLAY", "speed=\(String(format: "%.1f", telemetry.speedKmh)) rawSpeed=\(String(format: "%.3f", lastRawDisplaySpeed)) rpm=\(telemetry.rpm) rawMotor=\(lastRawMotorCount) voltage=\(String(format: "%.2f", telemetry.voltage)) soc=\(String(format: "%.0f", telemetry.batteryPercent)) motorTemp=\(String(format: "%.0f", telemetry.motorTemp)) controllerTemp=\(String(format: "%.0f", telemetry.controllerTemp)) mode=\(telemetry.mode.rawValue) flags=\(lastLiveFlags) type=\(dunenControllerTypeString) err=\(telemetry.errorCode) warn=\(telemetry.warningCode)")
        return true
    }

    private func decodeGenericFrame(_ data: Data) {
        appLogger.log("RX-IGNORED", "generic frame ignored len=\(data.count)")
    }

    private func decodeTelemetry(_ data: Data) {
        // Legacy decoder disabled.
    }

    private func calculateDerived(dt: Double) {
        telemetry.powerKw = (telemetry.voltage * telemetry.currentA) / 1000.0

        if telemetry.bmsSoc > 0 && telemetry.bmsSoc <= 100 {
            telemetry.batteryPercent = telemetry.bmsSoc
        }

        telemetry.voltageSag = max(0, lastVoltage - telemetry.voltage)

        if telemetry.speedKmh <= 0.3 {
            telemetry.rpm = 0
            telemetry.wheelRPM = 0
            telemetry.throttleOpen = 0
        }

        // Do NOT calculate lean from throttle/acceleration. No confirmed lean sensor yet.
        telemetry.gForce = 0
        telemetry.leanAngle = 0

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
        appLogger.log("BLE", "Characteristics for service \(service.uuid.uuidString): \(chars.map { $0.uuid.uuidString + "[" + AppLogManager.propertiesString($0.properties) + "]" }.joined(separator: ", "))")

        for ch in chars {
            if ch.uuid == characteristicFFE1 || ch.properties.contains(.notify) {
                notifyCharacteristic = ch
                appLogger.log("BLE", "Enable notify on \(ch.uuid.uuidString) props=\(AppLogManager.propertiesString(ch.properties))")
                peripheral.setNotifyValue(true, for: ch)
                if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                    secondaryWriteCharacteristic = ch
                }
            }

            if ch.uuid == characteristicFFF2 {
                writeCharacteristic = ch
            } else if writeCharacteristic == nil && (ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)) {
                writeCharacteristic = ch
            }

            if ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }

        if writeCharacteristic == nil { writeCharacteristic = secondaryWriteCharacteristic ?? notifyCharacteristic }
        connectionStatus = "Ready: FFE1 notify, FFF2/FFE1 read polling"
        appLogger.log("BLE", "Discovery ready notify=\(notifyCharacteristic?.uuid.uuidString ?? "nil") write=\(writeCharacteristic?.uuid.uuidString ?? "nil") secondary=\(secondaryWriteCharacteristic?.uuid.uuidString ?? "nil")")
        startPollTimer()
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
            appLogger.log("BLE", "Write callback error on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            tuningStore?.statusText = "Write error: \(error.localizedDescription)"
        } else {
            appLogger.log("BLE", "Write callback success on \(characteristic.uuid.uuidString)")
            tuningStore?.statusText = "Controller acknowledged write"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            connectionStatus = "Notify failed: \(error.localizedDescription)"
            return
        }
        appLogger.log("BLE", "Notify state \(characteristic.uuid.uuidString)=\(characteristic.isNotifying)")
        if characteristic.isNotifying { connectionStatus = "Receiving live packets" }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
