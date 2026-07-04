import Foundation
import CoreBluetooth

/// CoreBluetooth implementation of `MeshTransport` for real MeshCore radios.
/// Speaks the Nordic UART Service exactly as stock companion firmware exposes
/// it: writes go to the RX characteristic, frames arrive as notifications on
/// TX. One notification = one companion frame (BLE transport framing is
/// handled by the firmware).
final class BLETransport: NSObject, MeshTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.fellship.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?

    private let frameCaster = StreamMulticaster<Data>()
    private let stateCaster = StreamMulticaster<TransportState>(replayLast: true)
    private let radiosCaster = StreamMulticaster<[DiscoveredRadio]>(replayLast: true)

    private var currentState: TransportState = .disconnected {
        didSet { stateCaster.yield(currentState) }
    }
    private var found: [String: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var pendingWrites: [(Data, CheckedContinuation<Void, Error>)] = []
    private var writeInFlight = false
    private var shouldScanWhenPoweredOn = false
    private static let connectTimeout: TimeInterval = 15

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [
                                       CBCentralManagerOptionShowPowerAlertKey: true,
                                       // Lets iOS relaunch/reconnect us for
                                       // background BLE events.
                                       CBCentralManagerOptionRestoreIdentifierKey: "app.fellship.central",
                                   ])
        stateCaster.yield(.disconnected)
    }

    // MARK: - MeshTransport

    func frames() -> AsyncStream<Data> { frameCaster.stream(bufferingNewest: 256) }
    func states() -> AsyncStream<TransportState> { stateCaster.stream(bufferingNewest: 8) }
    func discovered() -> AsyncStream<[DiscoveredRadio]> { radiosCaster.stream(bufferingNewest: 8) }

    func startScanning() {
        queue.async { [self] in
            found.removeAll()
            radiosCaster.yield([])
            guard central.state == .poweredOn else {
                shouldScanWhenPoweredOn = true
                return
            }
            beginScan()
        }
    }

    func stopScanning() {
        queue.async { [self] in
            shouldScanWhenPoweredOn = false
            central.stopScan()
            if case .scanning = currentState { currentState = .disconnected }
        }
    }

    func connect(to radioID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard central.state == .poweredOn else {
                    continuation.resume(throwing: TransportError.bluetoothUnavailable)
                    return
                }
                var target = found[radioID]?.peripheral
                if target == nil, let uuid = UUID(uuidString: radioID) {
                    target = central.retrievePeripherals(withIdentifiers: [uuid]).first
                }
                guard let target else {
                    continuation.resume(throwing: TransportError.deviceNotFound)
                    return
                }
                central.stopScan()
                connectContinuation = continuation
                peripheral = target
                target.delegate = self
                currentState = .connecting
                central.connect(target, options: nil)
                // CoreBluetooth never times out connects on its own.
                queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
                    guard let self, self.connectContinuation != nil else { return }
                    self.connectFailed("The radio didn't respond. Make sure it's powered on and in range.")
                }
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            cleanupConnection()
        }
    }

    func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral, let rxCharacteristic, currentState.isConnected else {
                    continuation.resume(throwing: TransportError.notConnected)
                    return
                }
                pendingWrites.append((frame, continuation))
                drainWrites(peripheral: peripheral, characteristic: rxCharacteristic)
            }
        }
    }

    // MARK: - Internals (on queue)

    private func beginScan() {
        currentState = .scanning
        central.scanForPeripherals(withServices: [CBUUID(string: MeshCore.serviceUUID)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Writes are serialized: MeshCore radios expect one command frame at a
    /// time, and CoreBluetooth rejects overlapping writes-with-response.
    private func drainWrites(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !writeInFlight, let (frame, _) = pendingWrites.first else { return }
        writeInFlight = true
        let maxLen = peripheral.maximumWriteValueLength(for: .withResponse)
        if frame.count > maxLen {
            // A companion frame larger than the MTU cannot be split at this
            // layer (the firmware treats each write as a frame boundary).
            writeInFlight = false
            let (_, continuation) = pendingWrites.removeFirst()
            continuation.resume(throwing: TransportError.writeFailed(
                "Frame of \(frame.count) bytes exceeds the radio's \(maxLen)-byte write limit."))
            drainWrites(peripheral: peripheral, characteristic: characteristic)
            return
        }
        peripheral.writeValue(frame, for: characteristic, type: .withResponse)
    }

    private func cleanupConnection() {
        peripheral = nil
        rxCharacteristic = nil
        writeInFlight = false
        let writes = pendingWrites
        pendingWrites.removeAll()
        writes.forEach { $0.1.resume(throwing: TransportError.notConnected) }
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: TransportError.notConnected)
        }
        currentState = .disconnected
    }
}

extension BLETransport: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched us for a BLE event. Re-adopt any still-connected
        // peripheral so the session can resume.
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                restored.discoverServices([CBUUID(string: MeshCore.serviceUUID)])
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, shouldScanWhenPoweredOn {
            shouldScanWhenPoweredOn = false
            beginScan()
        }
        if central.state != .poweredOn, currentState.isConnected {
            cleanupConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "MeshCore radio"
        found[peripheral.identifier.uuidString] = (peripheral, RSSI.intValue)
        let radios = found.map { DiscoveredRadio(id: $0.key, name: $0.value.peripheral.name ?? name, rssi: $0.value.rssi) }
            .sorted { $0.rssi > $1.rssi }
        radiosCaster.yield(radios)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: MeshCore.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: TransportError.writeFailed(error?.localizedDescription ?? "connection failed"))
        }
        cleanupConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanupConnection()
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: MeshCore.serviceUUID) }) else {
            connectFailed("MeshCore service not found on this device.")
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: MeshCore.rxCharacteristicUUID),
                                            CBUUID(string: MeshCore.txCharacteristicUUID)],
                                           for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {
            connectFailed("Radio characteristics missing.")
            return
        }
        for characteristic in characteristics {
            if characteristic.uuid == CBUUID(string: MeshCore.rxCharacteristicUUID) {
                rxCharacteristic = characteristic
            }
            if characteristic.uuid == CBUUID(string: MeshCore.txCharacteristicUUID) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if rxCharacteristic != nil {
            currentState = .connected(deviceName: peripheral.name ?? "MeshCore radio")
            if let continuation = connectContinuation {
                connectContinuation = nil
                continuation.resume()
            }
        } else {
            connectFailed("Radio write channel missing.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        frameCaster.yield(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !pendingWrites.isEmpty else { return }
        let (_, continuation) = pendingWrites.removeFirst()
        writeInFlight = false
        if let error {
            continuation.resume(throwing: TransportError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
        if let rxCharacteristic {
            drainWrites(peripheral: peripheral, characteristic: rxCharacteristic)
        }
    }

    private func connectFailed(_ reason: String) {
        if let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: TransportError.writeFailed(reason))
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        cleanupConnection()
    }
}
