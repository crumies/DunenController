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
    @Published var isInitializing = false   // true while connected but no telemetry yet
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
    private var inFlightReadStart: Int?        // for 0x0400 live frame only
    private var inFlightSentAt: Date?
    private var outInFlightStart: Int?          // for output register block polls
    private var outInFlightSentAt: Date?
    private var lastDecodedStart: Int?
    private var bootScanDone: Bool = false
    private var didSendLiveEnable: Bool = false
    private var lastLiveNotifyAt: Date?
    private var lastStableRideMode: RideMode = .eco
    private var lastLiveFlags: Int = 0
    private var didReceiveGearData: Bool = false   // true once block A (608) delivered valid gear
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
        guard let p = connectedPeripheral else {
            tuningStore?.statusText = "Not connected"
            return
        }
        // Use writeCharacteristic (FFF2) if available, otherwise fall back to the notify char.
        // Both channels deliver responses back via the notify characteristic (FFE1).
        guard let c = writeCharacteristic ?? secondaryWriteCharacteristic ?? notifyCharacteristic else {
            tuningStore?.statusText = "No writable characteristic found"
            return
        }
        tuningStore?.markReading()

        // Read each tuning parameter with EXACT count to avoid byteCount=0x30 collision
        // with the live frame (which also has byteCount=0x30).
        // addr194 (row 99)  → count=2 → byteCount=4  (no collision)
        // addr418 (row 211) → count=4 → byteCount=8  covers 418 AND 420 (row 212)
        let addr194 = 194   // (99-2)*2
        let addr418 = 418   // (211-2)*2

        let writeType: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        pendingReadStarts.append(addr194)
        appLogger.log("TUNING-READ", "Sending read addr=\(addr194) count=2 via \(c.uuid.uuidString)")
        p.writeValue(DunenProtocol.modbusReadFrame(start: addr194, count: 2), for: c, type: writeType)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak p] in
            guard let self, let p else { return }
            guard let c2 = self.writeCharacteristic ?? self.secondaryWriteCharacteristic ?? self.notifyCharacteristic else { return }
            let wt: CBCharacteristicWriteType = c2.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            self.pendingReadStarts.append(addr418)
            self.appLogger.log("TUNING-READ", "Sending read addr=\(addr418) count=4 via \(c2.uuid.uuidString)")
            p.writeValue(DunenProtocol.modbusReadFrame(start: addr418, count: 4), for: c2, type: wt)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.tuningStore?.didLoadFromController == false {
                self.tuningStore?.isReading = false
                self.tuningStore?.statusText = "Read request sent — waiting for controller response."
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
        didReceiveGearData = false
        isInitializing = true

        pollFrames = []

        // Fast timer: Table-2 live frame at 0x0400 (reg 1024), count=24.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.requestLiveOutput() }
        }
        pollTimer?.fire()

        // Slower timer: rotates through output-table blocks. Brake (E) and gear/mode (A)
        // appear twice per rotation for ~0.4s worst-case latency on those critical signals.
        outputPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.requestOutputBlock() }
        }
        outputPollTimer?.fire()
        appLogger.log("POLL", "Started live=0.35s outputBlock=0.2s rotation=E,A,C,E,A,B,D,C")
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
        // 0x0400 live frame: byteCount=0x30 (24 words = 48 data bytes), total ~53 bytes.
        // Start 0x0400 = reg 1024. byteCount must be exactly 0x30.
        // Allow b.count >= 51 (3 header + 48 data; CRC bytes may be absent on some BLE stacks).
        guard b.count >= 51, b[0] == 0x01, b[1] == 0x03, b[2] == 0x30 else { return false }

        func u16(_ index: Int) -> Int {
            let o = 3 + index * 2
            guard o + 1 < b.count else { return 0 }
            return Int(UInt16(b[o]) << 8 | UInt16(b[o + 1]))
        }

        func fixed(_ frac: Int, _ whole: Int) -> Double {
            Double(Int16(bitPattern: UInt16(u16(whole)))) + Double(u16(frac)) / 65536.0
        }

        // Voltage at words 2(frac),3(int) — Udc in 0x0400 frame layout.
        // Must be in valid e-bike range (45–95V).
        let voltage = fixed(2, 3)
        return voltage >= 45 && voltage <= 95
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
        // OGearIn (row 309): 0=Empty/Park, 1 or 2=D, 4=R
        // Accept both 1 and 2 as Drive — firmware versions differ on which value means D.
        // OSpdMod (row 356): 0=ECO, 1=XC, 2=SPORTS
        let validGear = [0, 1, 2, 4].contains(telemetry.gearInputRaw)
        guard validGear else {
            appLogger.log("GEAR", "invalid gearInputRaw=\(telemetry.gearInputRaw) — skipping mode resolve")
            return
        }

        switch telemetry.gearInputRaw {
        case 4:   // R = reverse
            telemetry.mode = .reverse
            telemetry.reverseActive = true
            telemetry.parkingActive = false
            lastStableRideMode = .reverse
        case 0:   // Empty / Park
            telemetry.mode = .park
            telemetry.parkingActive = true
            telemetry.reverseActive = false
        default:  // 1 or 2 = D — drive; use OSpdMod for eco/xc/sports
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
        appLogger.log("GEAR", "gearIn=\(telemetry.gearInputRaw) gearOut=\(telemetry.gearRaw) spdMod=\(telemetry.speedModeRaw) → mode=\(telemetry.mode.rawValue)")
    }

    // Output-table poll blocks, rotated by outputPollTimer.
    // Order: C first so voltage decimals (OVkey) arrive within ~0.5s of connect.
    // Addr formula: (rowNo-2)*2. Word offset within block = (absAddr - blockStart).
    //
    // Block C: addr 682 (row 343) count=6 → OVkey(343), OVMon5V(344), OVMon15V(345)
    // Block A: addr 600 (row 303) count=22
    //   word 0,1  → row 303 (reg 600)  OXhFlag   (U32: non-zero = handbrake)
    //   word 6,7  → row 306 (reg 606)  OStMode   (U32)
    //   word 8,9  → row 307 (reg 608)  OErrCode  (U32, LOW=u16(9))
    //   word 10,11→ row 308 (reg 610)  OWarnCode (U32, LOW=u16(11))
    //   word 12,13→ row 309 (reg 612)  OGearIn   (0=Park, 2=Drive, 4=Rev)
    //   word 14,15→ row 310 (reg 614)  OGear     (U32)
    //   word 16,17→ row 311 (reg 616)  OACC ← NOTE: abs addr=(311-2)*2=618≠616. Use iq16At(18).
    //   word 18,19→ row 311 (reg 618)  OACC      (IQ16: throttle 0-1) ← CORRECT offset
    //   word 20,21→ row 312 (reg 620)  OTorLimit
    // Block B: addr 666 (row 335) count=4 → OMotTmp(335), OMosTmp(336)
    // Block D: addr 708 (row 356) count=14 → OSpdMod HIGH word=u16(0), OVechSpd words 12,13
    // Block E: addr 576 (row 290) count=2  → OBrK brake signal (both words checked)
    // Poll rotation: brake (E=576) and gear/mode (A=600) appear every other slot so they
    // update in ~0.4s worst case. Voltage (C=682) and temps (B=666) are less time-critical.
    // Timer fires at 0.2s → full rotation = 0.2 × 8 = 1.6s for slow blocks, ~0.4s for fast.
    private let outputPollConfigs: [(start: Int, count: Int)] = [
        (576,  2),   // E: OBrK brake — fast slot 1
        (600, 22),   // A: OGearIn / OXhFlag — fast slot 2
        (682,  6),   // C: OVkey voltage
        (576,  2),   // E: OBrK brake — fast slot 4 (repeated)
        (600, 22),   // A: OGearIn / OXhFlag — fast slot 5 (repeated)
        (666,  4),   // B: OMotTmp,OMosTmp
        (708, 14),   // D: OSpdMod + OVechSpd
        (682,  6),   // C: OVkey voltage (repeated to keep decimals fresh)
    ]
    private var outputPollIdx = 0

    /// Fast live frame poll — reads Table-2 from 0x0400 (reg 1024), count=24 words.
    /// Word layout (IQ16 = HIGH word frac, LOW word int):
    ///  0    → liveFlags (u16): bit0x04=reverse,0x08=XC,0x10=Sports,0x20=Park,0x40=brake
    ///  1    → (padding)
    ///  2,3  → Udc (IQ16) → bus voltage
    ///  4,5  → ActualSpeed (IQ16) → motor RPM — signed, negative in reverse
    ///  6,7  → controllerTemp / MosTmp (IQ16)
    ///  8,9  → motorTemp / MotorTmp (IQ16)
    ///  10,11 → Imag (IQ16) → phase current
    ///  12–17 → other live params
    ///  18   → motor angle (u16, raw)
    ///  20   → zero angle (u16, raw)
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

        // Table-2 live frame: start at 0x0400 (reg 1024), count=24 words
        // byteCount response = 48 bytes = 0x30
        let frame = DunenProtocol.modbusReadFrame(start: 0x0400, count: 24)
        inFlightReadStart = 0x0400
        inFlightSentAt = Date()
        developerStatus = "Live 0x0400"
        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic
        sendReadOnlyFrame(frame, via: target, peripheral: p, note: "live Table2 start=0x0400")
        liveProbeTick += 1
    }

    /// Slower output register block poll — uses its own in-flight tracker.
    private func requestOutputBlock() {
        guard isConnected, let p = connectedPeripheral else { return }

        if let start = outInFlightStart {
            let age = Date().timeIntervalSince(outInFlightSentAt ?? Date())
            if age < 0.45 {
                // Previous request still within window — don't pile up
                return
            }
            if age >= 0.45 {
                appLogger.log("OUT-POLL-TIMEOUT", "reg=\(start) no response after \(String(format:"%.2f",age))s — advancing")
                outInFlightStart = nil
                outInFlightSentAt = nil
            }
        }

        let cfg = outputPollConfigs[outputPollIdx % outputPollConfigs.count]
        outputPollIdx += 1
        let frame = DunenProtocol.modbusReadFrame(start: cfg.start, count: cfg.count)
        outInFlightStart = cfg.start
        outInFlightSentAt = Date()
        let expectedBC = cfg.count * 2
        appLogger.log("OUT-POLL", "TX reg=\(cfg.start) count=\(cfg.count) expectedByteCount=\(expectedBC) [0x\(String(format:"%02X",expectedBC))]")
        let target = notifyCharacteristic ?? secondaryWriteCharacteristic ?? writeCharacteristic
        sendReadOnlyFrame(frame, via: target, peripheral: p, note: "output-block addr=\(cfg.start)")
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

        // Primary live frame: Table-2 from 0x0400 (byteCount=0x30) — pass shape check.
        if isDunenLivePrimaryFrame(data) {
            lastLiveNotifyAt = Date()
            inFlightReadStart = nil
            inFlightSentAt = nil
            appLogger.log("PARSER", "live 0x0400 len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: 0x0400)
            return
        }

        guard isModbusRead else {
            decodeGenericFrame(data)
            return
        }

        // Tuning reads are sent via writeCharacteristic (FFF2) while live polls go via
        // notifyCharacteristic. Both responses arrive here. Check tuning FIRST so a pending
        // tuning response isn't consumed as a live-poll response.
        // Tuning reads now use exact counts (count=2 or count=4) → byteCount=4 or 8,
        // which can NEVER match the live frame byteCount=0x30. Accept any byteCount here.
        if !pendingReadStarts.isEmpty {
            let b2 = [UInt8](data)
            let bc = b2.count >= 3 ? Int(b2[2]) : 0
            // Accept any valid byteCount > 0; the live frame is already caught above by isDunenLivePrimaryFrame.
            if bc > 0, let start = pendingReadStarts.first {
                pendingReadStarts.removeFirst()
                let rawHex2 = b2.map { String(format: "%02X", $0) }.joined(separator: " ")
                appLogger.log("TUNING-RESP", "start=\(start) bc=\(bc) len=\(data.count) raw=\(rawHex2)")
                let values = DunenProtocol.parseParameterValues(from: data, expectedStart: start)
                appLogger.log("TUNING-PARSE", "parsed \(values.count) values: \(values.map { "addr\($0.key)=\($0.value)" }.joined(separator: " "))")
                tuningStore?.applyReadValues(values)
                return
            }
        }

        // Route the response to whoever sent the request.
        // If a wrong-size packet arrives while inFlightReadStart=0x0400, it is an output block
        // response that arrived in the same window. Clear inFlightReadStart and fall through to
        // the outInFlightStart handler so it is decoded correctly (not silently dropped).
        if let start = inFlightReadStart {
            let b2 = [UInt8](data)
            let bc = b2.count >= 3 ? Int(b2[2]) : 0
            if start == 0x0400 && bc != 0x30 {
                // Not the live frame — clear in-flight and fall through to outInFlightStart.
                appLogger.log("PARSER", "live-inFlight byteCount=\(bc)≠0x30 — clearing live in-flight, routing to output handler")
                inFlightReadStart = nil
                inFlightSentAt = nil
                // fall through (no return) to outInFlightStart block below
            } else {
                inFlightReadStart = nil
                inFlightSentAt = nil
                appLogger.log("PARSER", "live-resp start=0x\(String(start, radix: 16)) len=\(data.count)")
                _ = decodeDunenPage(data, expectedStart: start)
                return
            }
        }

        if let start = outInFlightStart {
            let b2 = [UInt8](data)
            let bc = b2.count >= 3 ? Int(b2[2]) : 0
            let expectedBC = 2 * (outputPollConfigs.first(where: { $0.start == start })?.count ?? 0)
            outInFlightStart = nil
            outInFlightSentAt = nil
            if expectedBC > 0 && bc != expectedBC {
                appLogger.log("OUT-PARSE-WARN", "reg=\(start) expected byteCount=\(expectedBC) got=\(bc) len=\(data.count) — will attempt decode anyway")
            }
            appLogger.log("PARSER", "output-block resp reg=\(start) bc=\(bc) len=\(data.count)")
            _ = decodeDunenPage(data, expectedStart: start)
            return
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

        let regDump = regs.enumerated().map { "r\(expectedStart + $0.offset)=\($0.element)" }.joined(separator: " ")
        appLogger.log("DECODE-RAW", "start=\(expectedStart)(0x\(String(expectedStart,radix:16))) words=\(regs.count) | \(regDump)")

        // Helper: IQ16 value from a pair of words (HIGH=frac at even index, LOW=int at odd index)
        func iq16At(_ evenIdx: Int) -> Double {
            fixedIntFrac(evenIdx, evenIdx + 1)
        }

        // Helper: U32 from a pair of words (HIGH first, LOW second)
        func u32At(_ evenIdx: Int) -> Int {
            (u16(evenIdx) << 16) | u16(evenIdx + 1)
        }

        switch expectedStart {
        case 0x0400:
            // Table-2 live frame from reg 0x0400 (1024), count=24 words. byteCount=0x30.
            // IQ16: HIGH word (even index) = fraction, LOW word (odd index) = integer.
            // Word layout (confirmed from official DUNEN app + register map):
            //  0    → liveFlags (u16): bit0x04=reverse,0x08=XC,0x10=Sports,0x20=Park,0x40=brake
            //  1    → (padding)
            //  2,3  → Udc (IQ16) → bus voltage
            //  4,5  → ActualSpeed (IQ16) → motor RPM — signed, negative in reverse
            //  6,7  → controllerTemp / MosTmp (IQ16)
            //  8,9  → motorTemp / MotorTmp (IQ16)
            //  10,11 → Imag (IQ16) → phase current
            //  12–17 → other live params
            //  18   → motor angle (u16, raw)
            //  20   → zero angle (u16, raw)
            guard byteCount >= 0x30 else {
                appLogger.log("PARSER", "0x0400 frame too short byteCount=\(byteCount) — skipped")
                return false
            }

            // Words 0,1: IQ16 parameter in this frame (not reliable for brake sensing).
            // Brake is determined solely by OBrK (block E addr 576) and OXhFlag (block A addr 600).
            // Store word01 for debug only.
            lastLiveFlags = (u16(0) << 16) | u16(1)

            // Voltage: Udc IQ16 words 2(frac),3(int).
            // Only used as initial seed — OVkey (block C) always overrides with 4dp precision.
            let udcVoltage = iq16At(2)
            if udcVoltage >= 45 && udcVoltage <= 95 && telemetry.voltage == 0 {
                telemetry.voltage = (udcVoltage * 100.0).rounded() / 100.0
                telemetry.batteryPercent = liIonSoc20s(telemetry.voltage)
                telemetry.bmsSoc = telemetry.batteryPercent
                appLogger.log("DECODE-LIVE", "voltage seed from Udc raw=\(String(format:"%.4f",udcVoltage)) → \(String(format:"%.2f",telemetry.voltage))V (seed only, OVkey takes over)")
            }

            // RPM: ActualSpeed IQ16 words 4(frac),5(int). Signed — negative in reverse.
            // Dead-band of 3 RPM filters idle rotor oscillation noise so it reads 0 when stopped.
            let motorRPMRaw = iq16At(4)
            let motorRPM = abs(motorRPMRaw)
            let prevRPM = telemetry.rpm
            telemetry.rpm = motorRPM >= 3.0 ? Int(motorRPM) : 0
            telemetry.wheelRPM = telemetry.rpm > 0 ? Double(telemetry.rpm) / finalDriveRatio : 0
            appLogger.log("DECODE-LIVE", "RPM raw=\(String(format:"%.4f",motorRPMRaw)) → \(telemetry.rpm) (prev=\(prevRPM))")

            // Controller temp: MosTmp IQ16 words 6(frac),7(int).
            let controllerT = iq16At(6)
            if controllerT >= -40 && controllerT <= 150 {
                telemetry.controllerTemp = (controllerT * 10.0).rounded() / 10.0
            }
            appLogger.log("DECODE-LIVE", "MosTmp raw=\(String(format:"%.4f",controllerT)) → \(String(format:"%.1f",telemetry.controllerTemp))°C")

            // Motor temp: MotorTmp IQ16 words 8(frac),9(int).
            let motorT = iq16At(8)
            if motorT >= -40 && motorT <= 150 {
                telemetry.motorTemp = (motorT * 10.0).rounded() / 10.0
            }
            appLogger.log("DECODE-LIVE", "MotorTmp raw=\(String(format:"%.4f",motorT)) → \(String(format:"%.1f",telemetry.motorTemp))°C")

            // Phase current (Imag): IQ16 words 10(frac),11(int). Negative during regen.
            let signedCurrent = iq16At(10)
            let rawCurrent = abs(signedCurrent)
            if rawCurrent >= 0 && rawCurrent <= 500 {
                telemetry.currentA = (rawCurrent * 100.0).rounded() / 100.0
            }
            appLogger.log("DECODE-LIVE", "Imag raw=\(String(format:"%.4f",signedCurrent)) → currentA=\(String(format:"%.2f",telemetry.currentA))A (scale:abs,round2dp)")

            // Regen level indicator from regen current while braking.
            if telemetry.brakeActive && signedCurrent < -0.5 {
                let regenA = abs(signedCurrent)
                if regenA < 5   { telemetry.regenLevel = 1 }
                else if regenA < 15 { telemetry.regenLevel = 2 }
                else                { telemetry.regenLevel = 3 }
            } else if !telemetry.brakeActive {
                telemetry.regenLevel = 0
            }

            // Motor angle: word 18 = raw u16 encoder position (0–65535, full 360°).
            // Zero angle: word 20 = encoder value at upright/calibration point.
            // Lean = signed difference from zero, scaled to degrees.
            // 65536 counts = 360°, so 1 count = 360/65536 ≈ 0.00549°.
            // Clamp display to ±42° (reasonable lean limit for a motorcycle/e-moto).
            let rawMotor = u16(18)
            let zero = u16(20)
            lastRawMotorCount = rawMotor
            telemetry.motorAngle = rawMotor
            telemetry.zeroAngle = zero
            // Signed wrap-around subtraction so the value crosses zero cleanly.
            let rawDiff = Int(Int16(bitPattern: UInt16((rawMotor &- zero) & 0xFFFF)))
            let degrees = Double(rawDiff) * 360.0 / 65536.0
            telemetry.leanAngle = max(-42.0, min(42.0, degrees))

            // Only update history on the live frame — output blocks don't change RPM/speed
            // so appending on every block would flood the graph with flat segments.
            calculateDerived(dt: 0.20)
            history.append(telemetry)
            updateRideStats(dt: 0.20)
            checkDiagnosticEvents()
            if isInitializing { isInitializing = false }
            appLogger.log("DISPLAY", "rpm=\(telemetry.rpm) spd=\(String(format:"%.1f",telemetry.speedKmh)) V=\(String(format:"%.4f",telemetry.voltage)) A=\(String(format:"%.2f",telemetry.currentA)) ctrlT=\(String(format:"%.1f",telemetry.controllerTemp)) motT=\(String(format:"%.1f",telemetry.motorTemp)) mode=\(telemetry.mode.rawValue) brake=\(telemetry.brakeActive) soc=\(String(format:"%.0f",telemetry.batteryPercent))%")
            return true

        case 600:
            // Block A starts at Modbus address 600. Word formula: wordIdx = absAddr - 600.
            // Row formula (DUNEN output table): absAddr = (row - 2) * 2.
            // Confirmed anchor: OVkey row 343 → addr 682, works at word 0 in block-C. ✓
            //
            // Row 302 → addr (302-2)*2=600 → words  0, 1  (first pair — unused/reserved)
            // Row 303 → addr (303-2)*2=602 → words  2, 3  OXhFlag   (U32: non-zero = brake)
            // Row 304 → addr (304-2)*2=604 → words  4, 5  (unused)
            // Row 305 → addr (305-2)*2=606 → words  6, 7  (unused)
            // Row 306 → addr (306-2)*2=608 → words  8, 9  OStMode   (U32)
            // Row 307 → addr (307-2)*2=610 → words 10,11  OErrCode  (U32, LOW=u16(11))
            // Row 308 → addr (308-2)*2=612 → words 12,13  OWarnCode (U32, LOW=u16(13))
            // Row 309 → addr (309-2)*2=614 → words 14,15  OGearIn   (0=Park, 2=Drive, 4=Rev)
            // Row 310 → addr (310-2)*2=616 → words 16,17  OGear     (U32)
            // Row 311 → addr (311-2)*2=618 → words 18,19  OACC      (IQ16: throttle 0-1)
            // Row 312 → addr (312-2)*2=620 → words 20,21  OTorLimit
            guard regs.count >= 16 else {
                appLogger.log("DECODE-WARN", "block-A reg=600 too few words=\(regs.count) expected≥16")
                break
            }

            // OXhFlag (row 303 → addr 602 → words 2,3): handbrake. Non-zero = brake pressed.
            let xhHi = u16(2); let xhLo = u16(3)
            let prevBrake = telemetry.brakeActive
            telemetry.brakeActive = (xhHi | xhLo) != 0
            appLogger.log("DECODE-A", "OXhFlag hi=\(xhHi) lo=\(xhLo) → brakeActive=\(telemetry.brakeActive) (prev=\(prevBrake))")

            // OErrCode (row 307 → addr 610 → words 10,11): LOW word = error code.
            let outErr  = u16(11)   // LOW word of OErrCode  (word 11)
            let outWarn = u16(13)   // LOW word of OWarnCode (word 13)
            telemetry.errorCode  = outErr
            telemetry.warningCode = outWarn

            // OGearIn (row 309 → addr 614 → words 14,15): 0=Park, 2=Drive, 4=Reverse.
            // Always use the LOW word (u16(15)) — 0 is a valid value meaning Park.
            // The old "use HIGH if LOW==0" logic prevented Park from ever being detected.
            let gearHi = u16(14); let gearLo = u16(15)
            let gearIn = gearLo
            // OGear (row 310 → addr 616 → words 16,17): LOW word = gear output.
            let gearOut = u16(17)
            telemetry.gearInputRaw = gearIn
            telemetry.gearRaw      = gearOut
            appLogger.log("DECODE-A", "OGearIn hi=\(gearHi) lo=\(gearLo) → gearIn=\(gearIn) | OGear lo=\(gearOut)")

            // OACC (row 311 → addr 618 → words 18,19): IQ16 throttle position 0.0–1.0.
            if regs.count >= 20 {
                let acc = iq16At(18)
                if acc >= 0 && acc <= 1.5 { telemetry.throttleOpen = min(1.0, max(0.0, acc)) }
                appLogger.log("DECODE-A", "OACC raw=\(String(format:"%.4f",acc)) → throttle=\(String(format:"%.1f",telemetry.throttleOpen*100))%")
            }

            resolveGearAndRideMode()

        case 666:
            // Output table Block B: addr 666 (row 335), count=4
            //  0,1 → row 335 OMotTmp  (IQ16) → motor temp
            //  2,3 → row 336 OMosTmp  (IQ16) → controller temp
            guard regs.count >= 4 else { break }

            let motTmp = iq16At(0)
            if motTmp >= -40 && motTmp <= 150 {
                telemetry.motorTemp = (motTmp * 10.0).rounded() / 10.0
            }
            let mosTmp = iq16At(2)
            if mosTmp >= -40 && mosTmp <= 150 {
                telemetry.controllerTemp = (mosTmp * 10.0).rounded() / 10.0
            }

        case 682:
            // Block C: addr 682 (row 343) count=6
            //  0,1 → row 343 OVkey    (IQ16) → high-accuracy bus voltage (4dp)
            //  2,3 → row 344 OVMon5V  (IQ16) → 5V rail
            //  4,5 → row 345 OVMon15V (IQ16) → 15V rail
            guard regs.count >= 6 else {
                appLogger.log("DECODE-WARN", "block-C reg=682 too few words=\(regs.count) expected≥6")
                break
            }

            let vKey = iq16At(0)
            appLogger.log("DECODE-C", "OVkey raw=\(String(format:"%.6f",vKey)) hi=\(regs[0]) lo=\(regs[1])")
            if vKey >= 45 && vKey <= 95 {
                let prevV = telemetry.voltage
                telemetry.voltage = (vKey * 10000.0).rounded() / 10000.0
                telemetry.batteryPercent = liIonSoc20s(telemetry.voltage)
                telemetry.bmsSoc = telemetry.batteryPercent
                appLogger.log("DECODE-C", "voltage \(String(format:"%.4f",prevV))→\(String(format:"%.4f",telemetry.voltage))V soc=\(String(format:"%.0f",telemetry.batteryPercent))%")
            } else {
                appLogger.log("DECODE-C", "OVkey=\(String(format:"%.4f",vKey)) out of range [45-95] — skipped")
            }

            let v5 = iq16At(2)
            if v5 > 0 && v5 < 8 {
                telemetry.internal5V = (v5 * 10000.0).rounded() / 10000.0
            }
            appLogger.log("DECODE-C", "OVMon5V raw=\(String(format:"%.4f",v5)) → \(String(format:"%.4f",telemetry.internal5V))V")

            let v15 = iq16At(4)
            if v15 > 0 && v15 < 20 {
                telemetry.internal15V = (v15 * 10000.0).rounded() / 10000.0
            }
            appLogger.log("DECODE-C", "OVMon15V raw=\(String(format:"%.4f",v15)) → \(String(format:"%.4f",telemetry.internal15V))V")

        case 708:
            // Output table Block D: addr 708 (row 356), count=14
            //  0,1  → row 356 OSpdMod  (U32: 0=ECO, 1=XC, 2=SPORTS)
            //  12,13 → row 362 OVechSpd (IQ16) → vehicle speed km/h
            //  (addr 720 = row 362; offset from block start = (720-708)/2 = 6 pairs = word 12,13)
            guard regs.count >= 2 else { break }

            // OSpdMod: confirmed from logs that r708=value, r709=0.
            // Value is in HIGH word (u16(0)). LOW word (u16(1)) is always 0.
            // Previous code used u16(1) (always 0 → always ECO). Fix: use u16(0).
            let spdMod = u16(0)   // HIGH word = mode value (0=ECO, 1=XC, 2=SPORTS)
            telemetry.speedModeRaw = spdMod
            appLogger.log("DECODE-D", "OSpdMod hi=\(u16(0)) lo=\(u16(1)) → spdMod=\(spdMod) currentMode=\(telemetry.mode.rawValue)")

            // OVechSpd: IQ16 motor RPM at words 12(frac),13(int).
            // This is motor RPM (same units as ActualSpeed in live frame), not km/h directly.
            // Convert to km/h using the bike's gearing: kmhPerMotorRPM = circumference/ratio.
            // Dead-band of 3 RPM matches the live frame threshold so both zero together.
            if regs.count >= 14 {
                let vechRPMRaw = iq16At(12)
                let vechRPM = abs(vechRPMRaw)
                if vechRPM < 20000 {
                    let kmh = vechRPM >= 3.0 ? (vechRPM * kmhPerMotorRPM * 10.0).rounded() / 10.0 : 0.0
                    telemetry.speedKmh = kmh
                    appLogger.log("DECODE-D", "OVechSpd raw=\(String(format:"%.4f",vechRPMRaw)) RPM → \(String(format:"%.1f",kmh))km/h (ratio=\(String(format:"%.5f",kmhPerMotorRPM)))")
                }
            }

            // Always call resolveGearAndRideMode — it gates park/reverse via gearInputRaw.
            resolveGearAndRideMode()

        case 576:
            // Block E: OBrK (row 290) brake signal. addr=(290-2)*2=576, count=2 → words 0,1.
            // OBrK is a U32; non-zero in EITHER word = brake pressed.
            // Previous code only checked LOW word (u16(1)) — may miss HIGH-word encoding.
            guard regs.count >= 2 else { break }
            let brkHi = u16(0)   // HIGH word of OBrK
            let brkLo = u16(1)   // LOW word of OBrK
            let prevBrakeE = telemetry.brakeActive
            // Only update from block E if OXhFlag (block A) is not already showing brake active,
            // so a sluggish block-E poll doesn't clear a live brakeActive from block A.
            let brkActive = (brkHi | brkLo) != 0
            if brkActive { telemetry.brakeActive = true }
            appLogger.log("DECODE-E", "OBrK hi=\(brkHi) lo=\(brkLo) → brakeActive=\(telemetry.brakeActive) (prev=\(prevBrakeE))")

        case 0x03E8:
            // Heartbeat/enable frame — no telemetry fields decoded here.
            appLogger.log("PARSER", "0x03E8 heartbeat len=\(data.count)")

        case 0x0418:
            // Fault/warning probe frame.
            if regs.count > 1 {
                telemetry.warningCode = u16(0)
                telemetry.errorCode   = u16(1)
            }

        default:
            break
        }

        telemetry.rawHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        telemetry.packetCount += 1

        // History and ride stats updated in the live frame case (0x03FE) only.
        // Output block cases call return early above, so we only reach here for
        // non-live-frame cases that fall through the switch without returning.
        calculateDerived(dt: 0.20)
        updateRideStats(dt: 0.20)
        checkDiagnosticEvents()
        return true
    }

    private func decodeGenericFrame(_ data: Data) {
        appLogger.log("RX-IGNORED", "generic frame ignored len=\(data.count)")
    }

    private func decodeTelemetry(_ data: Data) {
        // Legacy decoder disabled.
    }

    private func calculateDerived(dt: Double) {
        // Do NOT calculate power from amps — controller does not provide a kW register.
        // Leave powerKw as 0 so UI can show "—" instead of a derived/inaccurate value.
        telemetry.powerKw = 0

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
    // (voltage, soc%) breakpoints calibrated to official DunenConfiger app.
    // Confirmed: 79.36V = 77%, 74V = 48%.
    let curve: [(v: Double, soc: Double)] = [
        (84.0, 100.0),
        (82.0,  93.0),
        (80.5,  85.0),
        (79.36, 77.0),  // ← confirmed: official app shows 77% at 79.36V
        (79.0,  75.0),
        (77.5,  65.0),
        (76.0,  57.0),
        (74.0,  48.0),  // ← confirmed: bike BMS reads 48% at 74V
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
