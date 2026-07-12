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
    private var inFlightReadStart: Int?        // for 0x03F2 live frame only
    private var inFlightSentAt: Date?
    private var outInFlightStart: Int?          // for output register block polls
    private var outInFlightSentAt: Date?
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
    private var outputPollTimer: Timer?         // separate slower timer for reg blocks

    // Register probe result published to UI
    @Published var probeResult: String = ""
    @Published var probeInFlight: Bool = false
    private var probeInFlightStart: Int?

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
        // Function-code parameter table: address = (row-2)*2.
        // TuningParameter id=99 (row 99) → address (99-2)*2=194=0xC2.
        // Read 24 words (= 12 parameters) starting at address 0xC2, covering rows 99–110.
        let addr99 = (99 - 2) * 2    // 194 = 0xC2
        pendingReadStarts.append(addr99)
        p.writeValue(DunenProtocol.modbusReadFrame(start: addr99, count: 24), for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak p, weak c] in
            guard let self, let p, let c else { return }
            // TuningParameter id=211 (row 211) → address (211-2)*2=418=0x1A2.
            // TuningParameter id=212 (row 212) → address (212-2)*2=420=0x1A4 (adjacent, same block).
            let addr211 = (211 - 2) * 2   // 418 = 0x1A2
            self.pendingReadStarts.append(addr211)
            p.writeValue(DunenProtocol.modbusReadFrame(start: addr211, count: 24), for: c, type: c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
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
        outInFlightStart = nil
        outInFlightSentAt = nil
        lastDecodedStart = nil
        bootScanDone = true
        didSendLiveEnable = false
        didSendDunenTypeReads = false
        lastLiveNotifyAt = nil
        pollIndex = 0
        liveProbeTick = 0
        outputPollIdx = 0

        pollFrames = [
            (0x0418, DunenProtocol.modbusReadFrame(start: 0x0418, count: 0x0002)),
            // Extend to 0x03F2 (1010) to include ModeState, ActualSpeed (RPM)
            (0x03F2, DunenProtocol.modbusReadFrame(start: 0x03F2, count: 0x0026))
        ]

        // Fast timer: live frame starting at 0x03F2 to include RPM, mode, and all live values
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.requestLiveOutput() }
        }
        pollTimer?.fire()

        // Slower separate timer: output register blocks (362/338/266/314)
        // Runs on its own in-flight tracker so it never clashes with the 0x0400 poll.
        outputPollTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.requestOutputBlock() }
        }
        appLogger.log("POLL", "Started live=0.35s outputBlock=0.9s")
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

    private func isDunenLivePrimaryFrame(_ data: Data) -> Bool {
        let b = [UInt8](data)
        // Live frame starts at 0x03F2 (40 words = 80 data bytes = byteCount 0x50), total 85 bytes.
        // Validate by byteCount and require voltage+temps in realistic range.
        guard b.count >= 85, b[0] == 0x01, b[1] == 0x03, b[2] == 0x50 else { return false }

        func u16(_ index: Int) -> Int {
            let o = 3 + index * 2
            guard o + 1 < b.count else { return 0 }
            return Int(UInt16(b[o]) << 8 | UInt16(b[o + 1]))
        }

        func fixed(_ frac: Int, _ whole: Int) -> Double {
            Double(Int16(bitPattern: UInt16(u16(whole)))) + Double(u16(frac)) / 65536.0
        }

        // Voltage: frac=word16, int=word17 (Udc at address 1026, offset from 0x03F2=1010: (1026-1010)/2=8 pairs → word16,17)
        let voltage = fixed(16, 17)
        // Controller temp: frac=word20, int=word21 (MosTmp at 1030, offset=(1030-1010)/2=10 pairs → word20,21)
        let controllerT = fixed(20, 21)
        // Motor temp: frac=word22, int=word23 (MotorTmp at 1032 → word22,23)
        let motorT = fixed(22, 23)

        return voltage >= 45 && voltage <= 95 &&
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

    // Reg 338 polled every 0.9s for OVMon5V (344) and OVMon15V (345).
    private let outputPollStarts: [Int] = [338]
    private var outputPollIdx = 0

    /// Fast live frame poll (start=0x03F2) — only handles the primary dashboard frame.
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
            if age < 0.5 { return }
            appLogger.log("POLL-TIMEOUT", "Dropping live in-flight 0x\(String(start, radix: 16))")
            inFlightReadStart = nil
            inFlightSentAt = nil
        }

        // Start at 0x03F2 (reg 1010) and read 40 words to cover through ErrCode (reg 1048).
        // Word layout: Idref(0,1) Iqref(2,3) AccPedal(4,5) DebugEnable(6,7)
        //              EnableState(8,9) ModeState(10,11) ActualSpeed/RPM(12,13)
        //              ActualTorque(14,15) Udc/voltage(16,17) Imag/current(18,19)
        //              MosTmp/ctrlTemp(20,21) MotorTmp(22,23) Idfed(24,25) Iqfed(26,27)
        //              Umag/phaseV(28,29) IdEst/busCur(30,31) Dangle/angle(32,33)
        //              ZeroAngle(34,35) WarnCode(36,37) ErrCode(38,39)
        let frame = DunenProtocol.modbusReadFrame(start: 0x03F2, count: 0x0028)
        inFlightReadStart = 0x03F2
        inFlightSentAt = Date()
        developerStatus = "Live 0x03F2"
        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic
        sendReadOnlyFrame(frame, via: target, peripheral: p, note: "live start=0x400")
        liveProbeTick += 1
    }

    /// Slower output register block poll — uses its own in-flight tracker, never touches inFlightReadStart.
    private func requestOutputBlock() {
        guard isConnected, let p = connectedPeripheral else { return }

        if let start = outInFlightStart {
            let age = Date().timeIntervalSince(outInFlightSentAt ?? Date())
            if age < 1.2 {
                appLogger.log("OUT-POLL", "Still waiting for reg \(start) response")
                return
            }
            appLogger.log("OUT-POLL-TIMEOUT", "Dropping output block reg \(start)")
            outInFlightStart = nil
            outInFlightSentAt = nil
        }

        guard !outputPollStarts.isEmpty else { return }
        let start = outputPollStarts[outputPollIdx % outputPollStarts.count]
        outputPollIdx += 1
        let frame = DunenProtocol.modbusReadFrame(start: start, count: 24)
        outInFlightStart = start
        outInFlightSentAt = Date()
        appLogger.log("OUT-POLL", "Requesting reg \(start) count=24")
        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic
        sendReadOnlyFrame(frame, via: target, peripheral: p, note: "output-block reg=\(start)")
    }

    /// Send a one-shot Modbus read for any register range. Result shows in probeResult.
    func probeRegister(start: Int, count: Int) {
        guard isConnected, let p = connectedPeripheral else {
            probeResult = "Not connected"
            return
        }
        probeInFlight = true
        probeInFlightStart = start
        probeResult = "Waiting for reg \(start)…"
        let frame = DunenProtocol.modbusReadFrame(start: start, count: count)
        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic
        appLogger.log("PROBE", "Sending probe reg=\(start) count=\(count)")
        sendReadOnlyFrame(frame, via: target, peripheral: p, note: "probe reg=\(start) count=\(count)")
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
        outputPollTimer?.invalidate()
        outputPollTimer = nil
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

        // Primary live frame: starts at 0x03F2 (byteCount=0x4C) — pass shape check.
        if isDunenLivePrimaryFrame(data) {
            lastLiveNotifyAt = Date()
            inFlightReadStart = nil
            inFlightSentAt = nil
            appLogger.log("PARSER", "live 0x03F2 len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: 0x03F2)
            return
        }

        guard isModbusRead else {
            decodeGenericFrame(data)
            return
        }

        // Route the response to whoever sent the request.
        // For the live 0x03F2 slot: only accept if byteCount==0x50 (80 bytes = 40 u16 words).
        // Reject short/wrong-size responses so firmware strings don't get decoded as telemetry.
        if let start = inFlightReadStart {
            let b2 = [UInt8](data)
            let bc = b2.count >= 3 ? Int(b2[2]) : 0
            // 0x03F2 frame expects byteCount=0x50 (40 words×2); reject wrong-size responses
            if start == 0x03F2 && bc != 0x50 {
                appLogger.log("PARSER", "live-resp rejected wrong byteCount=\(bc) for 0x03F2 — not a live frame")
                // don't clear inFlightReadStart — wait for the real frame
                return
            }
            inFlightReadStart = nil
            inFlightSentAt = nil
            appLogger.log("PARSER", "live-resp start=0x\(String(start, radix: 16)) len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: start)
            return
        }

        if let start = outInFlightStart {
            outInFlightStart = nil
            outInFlightSentAt = nil
            appLogger.log("PARSER", "output-block resp start=\(start) len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: start)
            return
        }

        // Tuning read responses — pendingReadStarts holds Modbus addresses (194, 418, etc.)
        if !pendingReadStarts.isEmpty {
            let b2 = [UInt8](data)
            let bc = b2.count >= 3 ? Int(b2[2]) : 0
            // Each tuning block is 24 u16 = 48 bytes = byteCount 0x30
            if bc == 0x30, let start = pendingReadStarts.first {
                pendingReadStarts.removeFirst()
                appLogger.log("PARSER", "tuning resp start=\(start) len=\(data.count)")
                let values = DunenProtocol.parseParameterValues(from: data, expectedStart: start)
                tuningStore?.applyReadValues(values)
                return
            }
        }

        if let start = probeInFlightStart {
            probeInFlightStart = nil
            probeInFlight = false
            // Build human-readable dump of all 32-bit values in the block.
            // DUNEN IQ16 encoding: HIGH 16-bit word = fraction, LOW 16-bit word = integer.
            let b = [UInt8](data)
            let byteCount = b.count >= 3 ? Int(b[2]) : 0
            var lines: [String] = ["Addr\tHIGH(frac)\tLOW(int)\tIQ16 value\tU32 raw"]
            var offset = 3
            var regAddr = start
            let probeEnd = min(b.count - 2, 3 + byteCount)
            while offset + 3 < probeEnd {
                let hiWord = Int(b[offset]) << 8 | Int(b[offset+1])      // HIGH 16b = frac
                let loWord = Int(b[offset+2]) << 8 | Int(b[offset+3])    // LOW 16b = integer
                let intPart = Double(Int16(bitPattern: UInt16(loWord)))
                let iq16val = intPart + Double(hiWord) / 65536.0
                let raw32 = Int32(bitPattern: (UInt32(hiWord) << 16) | UInt32(loWord))
                lines.append("\(regAddr)\t\(hiWord)\t\(loWord)\t\(String(format:"%.4f",iq16val))\t\(raw32)")
                regAddr += 2
                offset += 4
            }
            probeResult = lines.joined(separator: "\n")
            appLogger.log("PROBE", "result for start=\(start): \(probeResult)")
            return
        }

        appLogger.log("RX-UNMATCHED", "0x03 response no in-flight request len=\(data.count) hex=\(hex)")
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
        case 0x03F2:
            // Live frame from reg 1010 (0x03F2), count=40 words.
            // Must have byteCount=0x50 (80 data bytes = 40 words).
            guard byteCount >= 0x50 else {
                appLogger.log("PARSER", "0x03F2 frame too short byteCount=\(byteCount) — skipped")
                return false
            }

            // Word layout (each IQ16 param: HIGH word = fraction, LOW word = integer):
            // words 0,1   → 1010 Idref
            // words 2,3   → 1012 Iqref
            // words 4,5   → 1014 AccPedal (U32, throttle ADC 0–4096)
            // words 6,7   → 1016 DebugEnable
            // words 8,9   → 1018 EnableState (U32)
            // words 10,11 → 1020 ModeState (U32: 0=throttle, 1=speed, 2=comm)
            // words 12,13 → 1022 ActualSpeed (IQ16) — motor RPM (signed)
            // words 14,15 → 1024 ActualTorque (IQ16)
            // words 16,17 → 1026 Udc (IQ16) — bus voltage; HIGH word has embedded flags
            // words 18,19 → 1028 Imag (IQ16) — phase current (peak)
            // words 20,21 → 1030 MosTmp (IQ16) — controller (MOSFET) temp
            // words 22,23 → 1032 MotorTmp (IQ16) — motor temp
            // words 24,25 → 1034 Idfed (IQ16) — D-axis current
            // words 26,27 → 1036 Iqfed (IQ16) — Q-axis current
            // words 28,29 → 1038 Umag (IQ16) — phase voltage magnitude
            // words 30,31 → 1040 IdEst (IQ16) — bus current estimate
            // words 32,33 → 1042 Dangle (U32) — motor encoder angle
            // words 34,35 → 1044 ZeroAngle (U32) — encoder zero offset
            // words 36,37 → 1046 WarnCode (U32)
            // words 38,39 → 1048 ErrCode (U32)

            // Voltage: Udc IQ16 frac=u16(16), int=u16(17)
            let voltage = fixedIntFrac(16, 17)
            if voltage >= 45 && voltage <= 95 {
                // Show 4 decimal places of IQ16 precision
                telemetry.voltage = (voltage * 10000.0).rounded() / 10000.0
                telemetry.batteryPercent = liIonSoc20s(telemetry.voltage)
                telemetry.bmsSoc = telemetry.batteryPercent
            }

            // Motor RPM: ActualSpeed IQ16 frac=u16(12), int=u16(13). Signed (negative = reverse).
            let motorRPMRaw = fixedIntFrac(12, 13)
            let motorRPM = abs(motorRPMRaw)
            telemetry.rpm = motorRPM >= 0.5 ? Int(motorRPM) : 0
            if telemetry.rpm == 0 {
                telemetry.speedKmh = 0
                telemetry.wheelRPM = 0
            } else {
                let kmh = motorRPM * kmhPerMotorRPM
                telemetry.speedKmh = (kmh * 10.0).rounded() / 10.0
                telemetry.wheelRPM = motorRPM / finalDriveRatio
            }

            // Controller (MOSFET) temp: MosTmp IQ16 frac=u16(20), int=u16(21)
            let controllerT = fixedIntFrac(20, 21)
            if controllerT >= -40 && controllerT <= 150 {
                telemetry.controllerTemp = (controllerT * 10.0).rounded() / 10.0
            }

            // Motor temp: MotorTmp IQ16 frac=u16(22), int=u16(23)
            let motorT = fixedIntFrac(22, 23)
            if motorT >= -40 && motorT <= 150 {
                telemetry.motorTemp = (motorT * 10.0).rounded() / 10.0
            }

            // Phase current (Imag): IQ16 frac=u16(18), int=u16(19). High word has embedded flags
            // but they are in the upper bits so integer precision is unaffected.
            // abs() because current is negative during regenerative braking.
            let rawCurrent = abs(fixedIntFrac(18, 19))
            if rawCurrent >= 0 && rawCurrent <= 500 {
                telemetry.currentA = (rawCurrent * 100.0).rounded() / 100.0
            }

            // D/Q axis currents for advanced info
            telemetry.torque = abs(fixedIntFrac(24, 25))   // Idfed as proxy

            // Phase voltage: Umag IQ16 frac=u16(28), int=u16(29)
            let phaseV = fixedIntFrac(28, 29)
            if phaseV >= 0 && phaseV <= 120 {
                telemetry.phaseVoltage = (phaseV * 100.0).rounded() / 100.0
            }

            // Motor encoder angle: Dangle U32 (words 32,33)
            // U32 = (u16(32) << 16) | u16(33)
            let rawMotor = (u16(32) << 16) | u16(33)
            lastRawMotorCount = rawMotor
            telemetry.motorAngle = rawMotor & 0x3FFF  // 14-bit encoder typical

            // Zero angle: ZeroAngle U32 (words 34,35)
            let zero = (u16(34) << 16) | u16(35)
            telemetry.zeroAngle = zero & 0x3FFF

            // Lean angle from encoder difference (encoder-based lean, not IMU).
            // Use UInt32 wrapping subtraction to safely handle underflow.
            let rawMotorU = UInt32(bitPattern: Int32(rawMotor & 0x3FFF))
            let zeroU     = UInt32(bitPattern: Int32(zero     & 0x3FFF))
            let angleDiffU = (rawMotorU &- zeroU) & 0x3FFF
            // Re-interpret as signed 14-bit value: if ≥ 8192, it wraps negative
            let angleDiffSigned = angleDiffU >= 8192 ? Int32(angleDiffU) - 16384 : Int32(angleDiffU)
            telemetry.leanAngle = Double(angleDiffSigned) * 360.0 / 16384.0

            // Warning and error codes: WarnCode(36,37) ErrCode(38,39) — U32 HIGH+LOW
            if regs.count > 37 {
                telemetry.warningCode = (u16(36) << 16) | u16(37)
            }
            if regs.count > 39 {
                telemetry.errorCode = (u16(38) << 16) | u16(39)
            }

            // Brake signal: Fn.OBrK is bit 5 of the HIGH word of Udc (u16(16)).
            // The HIGH word contains IQ16 fraction + embedded flags; bit 5 = brake.
            // Note: the fraction value may accidentally set this bit — treat as advisory only.
            let udcHighWord = u16(16)
            telemetry.brakeActive = (udcHighWord & 0x20) != 0

            // Mode and gear from Udc HIGH word flags:
            // Bit 7 = Fn.ORD (reverse/D), Bit 6 = Fn.OPD (P), Bits 3-4 = Fn.OSpdMod (0/1/2/3)
            // ModeState (words 10,11) gives U32 operating mode:
            //   0 = throttle (oil-gate) mode → speed mode bits determine eco/xc/sports
            //   1 = speed mode
            //   2 = communication control mode
            let modeState = u16(11)   // LOW word of ModeState (integer part)
            let spdModBits = (udcHighWord >> 3) & 0x03   // bits 3-4

            if (udcHighWord & 0x80) != 0 {
                // Fn.ORD set → reverse/D gear
                telemetry.mode = .reverse
                telemetry.reverseActive = true
                telemetry.parkingActive = false
                lastStableRideMode = .reverse
            } else if (udcHighWord & 0x40) != 0 {
                // Fn.OPD set → park gear
                telemetry.mode = .park
                telemetry.parkingActive = true
                telemetry.reverseActive = false
            } else {
                telemetry.parkingActive = false
                telemetry.reverseActive = false
                // Speed mode from Fn.OSpdMod bits (3-4 of HIGH word)
                switch spdModBits {
                case 0:
                    telemetry.mode = .eco
                    telemetry.speedModeRaw = 0
                    lastStableRideMode = .eco
                case 1:
                    telemetry.mode = .xc
                    telemetry.speedModeRaw = 1
                    lastStableRideMode = .xc
                case 2, 3:
                    telemetry.mode = .sports
                    telemetry.speedModeRaw = 2
                    lastStableRideMode = .sports
                default:
                    telemetry.mode = lastStableRideMode
                    telemetry.speedModeRaw = { switch lastStableRideMode {
                        case .eco: return 0; case .xc: return 1; default: return 2
                    }}()
                }
            }

            // AccPedal: U32 throttle ADC 0–4096 (words 4,5)
            let throttleADC = Double((u16(4) << 16) | u16(5))
            telemetry.throttleOpen = min(1.0, max(0.0, throttleADC / 4096.0))

            _ = modeState  // suppress unused warning

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

        case 338:
            // Function-code output parameter table polled at address 338, count=24.
            // Each 32-bit IQ16 parameter uses two 16-bit words (HIGH=fraction, LOW=integer).
            // Addresses relative to start 338:
            //   regs[0],regs[1] → addr 338
            //   regs[2],regs[3] → addr 340
            //   regs[4],regs[5] → addr 342
            //   regs[6],regs[7] → addr 344 (but OVKey is at addr 342 or 343?)
            //
            // From the controller parameter table:
            //   OVKey (high-accuracy bus voltage) at register 343 → HIGH=regs[5], LOW=regs[6]
            //   OVMon5V at register 344 → HIGH=regs[6], LOW=regs[7]  (wait, overlaps OVKey LOW)
            //
            // Registers 343 and 344 are consecutive 16-bit addresses. OVKey and OVMon5V are
            // separate 32-bit parameters at EVEN addresses. Most likely:
            //   OVKey    at address 342: HIGH=regs[4], LOW=regs[5] → IQ16
            //   OVMon5V  at address 344: HIGH=regs[6], LOW=regs[7] → IQ16
            //   OVMon15V at address 346: HIGH=regs[8], LOW=regs[9] → IQ16
            //
            // IQ16 convention: result = s16(LOW) + u16(HIGH)/65536.0
            if regs.count > 9 {
                // OVKey (high-accuracy bus voltage) — use to refine telemetry.voltage decimals
                let ovKeyInt  = Double(Int16(bitPattern: UInt16(regs[5])))
                let ovKeyFrac = Double(regs[4])
                let ovKey = ovKeyInt + ovKeyFrac / 65536.0
                if ovKey >= 45 && ovKey <= 95 {
                    telemetry.voltage = (ovKey * 10000.0).rounded() / 10000.0
                }

                // OVMon5V (5V rail)
                let v5int  = Double(Int16(bitPattern: UInt16(regs[7])))
                let v5frac = Double(regs[6])
                let v5 = v5int + v5frac / 65536.0
                if v5 > 0 && v5 < 8 { telemetry.internal5V = (v5 * 10000.0).rounded() / 10000.0 }

                // OVMon15V (15V rail)
                let v15int  = Double(Int16(bitPattern: UInt16(regs[9])))
                let v15frac = Double(regs[8])
                let v15 = v15int + v15frac / 65536.0
                if v15 > 0 && v15 < 20 { telemetry.internal15V = (v15 * 10000.0).rounded() / 10000.0 }
            }

        default:
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

        // Do NOT zero rpm/speed/leanAngle here — set by the decoder directly.
        telemetry.gForce = 0
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

/// Read a DUNEN 32-bit signed register from a [Int] array of u16 words.
/// DUNEN output tables store each logical register as 2 consecutive u16 words: hi word first.
/// `idx` is the logical register index (0-based from block start).
/// Returns the signed 32-bit integer value as Double.
private func reg32s(_ regs: [Int], idx: Int) -> Double {
    let hi = regs[safe: idx * 2] ?? 0
    let lo = regs[safe: idx * 2 + 1] ?? 0
    let raw = Int32(bitPattern: (UInt32(hi) << 16) | UInt32(lo))
    return Double(raw)
}

/// Piecewise linear voltage→SOC for a 20s LG Li-ion pack (nominal 72V).
/// Breakpoints calibrated to real LG cell discharge curve; 74V = ~49%.
/// Full = 84V (4.2V×20) = 100%, empty = 60V (3.0V×20) = 0%.
private func liIonSoc20s(_ voltage: Double) -> Double {
    // (voltage, soc%) breakpoints — real Li-ion curve is flat in the middle.
    let curve: [(v: Double, soc: Double)] = [
        (84.0, 100.0),
        (82.0,  93.0),
        (80.5,  85.0),
        (79.0,  75.0),
        (77.5,  65.0),
        (76.0,  57.0),
        (74.0,  48.0),  // ← calibrated: bike BMS reads 48% at 74V
        (72.5,  40.0),
        (71.0,  30.0),
        (69.5,  20.0),
        (68.0,  12.0),
        (66.0,   5.0),
        (60.0,   0.0),
    ]
    if voltage >= curve[0].v { return 100.0 }
    if voltage <= curve[curve.count - 1].v { return 0.0 }
    for i in 0..<(curve.count - 1) {
        let hi = curve[i], lo = curve[i + 1]
        if voltage <= hi.v && voltage >= lo.v {
            let t = (voltage - lo.v) / (hi.v - lo.v)
            return (lo.soc + t * (hi.soc - lo.soc)).rounded()
        }
    }
    return 0.0
}
