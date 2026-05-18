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
    @Published var connectionStatus: String = "Bluetooth not ready"
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectedName: String?
    @Published var telemetry = Telemetry()
    @Published var packetLog: [String] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?

    private let serviceFFE0 = CBUUID(string: "FFE0")
    private let characteristicFFE1 = CBUUID(string: "FFE1")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            connectionStatus = "Bluetooth is not powered on"
            return
        }

        discoveredDevices.removeAll()
        isScanning = true
        connectionStatus = "Scanning for DUNEN / FFE0..."

        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if self.isScanning {
                self.central.stopScan()
                self.isScanning = false
                self.connectionStatus = self.discoveredDevices.isEmpty ? "No DUNEN devices found" : "Scan finished"
            }
        }
    }

    func connect(to device: DiscoveredBLEDevice) {
        central.stopScan()
        isScanning = false
        connectionStatus = "Connecting to \(device.name)..."
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func addPacket(_ data: Data) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        telemetry.rawHex = hex
        telemetry.packetCount += 1
        packetLog.insert(hex, at: 0)
        if packetLog.count > 40 { packetLog.removeLast() }

        decodeBestGuess(data)
    }

    // Best-guess parser only. Real RPM/speed/brake byte offsets must be tuned after comparing raw packets.
    private func decodeBestGuess(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8 else { return }

        // These guesses are intentionally conservative so the app can run now.
        // Send raw packets later and these offsets can be corrected.
        if b.count >= 12 {
            let vRaw = UInt16(b[2]) | (UInt16(b[3]) << 8)
            let rpmRaw = UInt16(b[4]) | (UInt16(b[5]) << 8)
            let speedRaw = UInt16(b[6]) | (UInt16(b[7]) << 8)

            let voltage = Double(vRaw) / 10.0
            if voltage > 20 && voltage < 120 { telemetry.voltage = voltage }

            let rpm = Int(rpmRaw)
            if rpm >= 0 && rpm < 20000 { telemetry.rpm = rpm }

            let speed = Double(speedRaw) / 10.0
            if speed >= 0 && speed < 180 { telemetry.speedKmh = speed }
        }

        let flag = b.last ?? 0
        telemetry.frontBrakePressed = (flag & 0x01) != 0
        telemetry.rearBrakePressed = (flag & 0x02) != 0
        telemetry.regenActive = (flag & 0x04) != 0

        if b.count > 14 {
            telemetry.soc = min(100, max(0, Double(b[8])))
            telemetry.controllerTemp = Double(Int8(bitPattern: b[9]))
            telemetry.motorTemp = Double(Int8(bitPattern: b[10]))
            telemetry.throttlePercent = min(100, max(0, Double(b[11])))
            telemetry.currentA = Double(Int8(bitPattern: b[12]))
            telemetry.phaseCurrentA = Double(UInt16(b[13]) | (UInt16(b[14]) << 8)) / 10.0
        }
    }

    private func shouldShowDevice(name: String, advertisementData: [String: Any]) -> Bool {
        if name.uppercased().contains("DUNEN") { return true }

        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            if uuids.contains(serviceFFE0) { return true }
        }

        return false
    }
}

extension DunenBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectionStatus = "Bluetooth ready"
        case .poweredOff: connectionStatus = "Bluetooth off"
        case .unauthorized: connectionStatus = "Bluetooth permission denied"
        case .unsupported: connectionStatus = "Bluetooth not supported"
        default: connectionStatus = "Bluetooth state: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown"

        guard shouldShowDevice(name: name, advertisementData: advertisementData) else { return }

        let device = DiscoveredBLEDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue
        )

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedName = peripheral.name ?? "DUNEN"
        connectionStatus = "Connected. Discovering services..."
        peripheral.discoverServices([serviceFFE0])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        connectionStatus = "Failed to connect: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        connectedName = nil
        connectedPeripheral = nil
        connectionStatus = "Disconnected"
    }
}

extension DunenBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionStatus = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            connectionStatus = "No services found"
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }

        connectionStatus = "Discovering characteristics..."
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            connectionStatus = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            let props = characteristic.properties

            if characteristic.uuid == characteristicFFE1 || props.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
                connectionStatus = "Subscribed to \(characteristic.uuid.uuidString)"
            }

            if props.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            connectionStatus = "Read/notify error: \(error.localizedDescription)"
            return
        }

        guard let data = characteristic.value else { return }
        addPacket(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            connectionStatus = "Notify failed: \(error.localizedDescription)"
            return
        }

        if characteristic.isNotifying {
            connectionStatus = "Receiving live packets from \(characteristic.uuid.uuidString)"
        }
    }
}
