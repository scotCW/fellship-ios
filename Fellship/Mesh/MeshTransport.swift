import Foundation

enum TransportState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case connected(deviceName: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// A discovered radio, before connection.
struct DiscoveredRadio: Identifiable, Equatable, Sendable {
    var id: String       // platform identifier (CBPeripheral UUID / sim ID)
    var name: String
    var rssi: Int
}

/// Abstraction over "a way to exchange MeshCore companion frames with a
/// radio". Two implementations ship: CoreBluetooth against real hardware, and
/// an in-memory simulator that powers demo mode, previews, and tests.
///
/// The stream factories return a **new independent stream per call** so that
/// multiple consumers (session, UI, tests) can subscribe safely.
protocol MeshTransport: AnyObject, Sendable {
    /// Complete companion-protocol frames received from the radio.
    func frames() -> AsyncStream<Data>
    /// Connection state changes; the current state is replayed on subscribe.
    func states() -> AsyncStream<TransportState>
    /// Radios visible right now (updated while scanning).
    func discovered() -> AsyncStream<[DiscoveredRadio]>

    func startScanning()
    func stopScanning()
    func connect(to radioID: String) async throws
    func disconnect()
    /// Sends one complete companion-protocol frame.
    func send(_ frame: Data) async throws
}

enum TransportError: Error, LocalizedError {
    case notConnected
    case bluetoothUnavailable
    case deviceNotFound
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "No radio is connected."
        case .bluetoothUnavailable: return "Bluetooth is not available."
        case .deviceNotFound: return "The radio could not be found."
        case .writeFailed(let reason): return "Sending to the radio failed: \(reason)"
        }
    }
}
