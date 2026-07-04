import Foundation
import SwiftUI

/// Composition root. Owns every service, wires them together, and manages the
/// radio connection lifecycle (real BLE or the demo simulator).
@MainActor
final class AppState: ObservableObject {
    let settings: AppSettings
    let store: LocalStore
    let notifications: NotificationService
    let engine: RoomEngine
    let location: LocationService
    let background: BackgroundMonitor
    let offlineMaps: OfflineMapManager

    @Published private(set) var transportState: TransportState = .disconnected
    @Published private(set) var radios: [DiscoveredRadio] = []
    @Published private(set) var selfInfo: MeshCore.SelfInfo?
    @Published private(set) var deviceInfo: MeshCore.DeviceInfo?
    @Published private(set) var batteryMilliVolts: UInt16?
    @Published var connectionError: String?

    private var transport: MeshTransport?
    private(set) var session: MeshSession?
    private var streamTasks: [Task<Void, Never>] = []
    private var sessionEventTask: Task<Void, Never>?
    private var batteryTimer: Timer?
    /// Set while the user is deliberately disconnecting, so the drop isn't
    /// treated as a link failure to recover from.
    private var userInitiatedDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    /// Serializes connection attempts: a user tap racing the auto-reconnect
    /// must never tear down the link the other one just established.
    private var isConnecting = false

    init() {
        settings = AppSettings()
        // A database failure at startup is unrecoverable; fall back to an
        // ephemeral store so the app can at least run and explain itself.
        store = (try? LocalStore()) ?? LocalStore.ephemeral()
        notifications = NotificationService()
        engine = RoomEngine(store: store, settings: settings, notifications: notifications)
        location = LocationService()
        background = BackgroundMonitor()
        offlineMaps = OfflineMapManager()

        wireServices()

        if settings.demoMode {
            Task { await enableDemoMode() }
        } else if settings.lastRadioIdentifier != nil {
            // Quietly resume the last radio, with retries — Bluetooth can
            // take several seconds to power up after launch.
            ensureTransport()
            scheduleReconnect(firstDelaySeconds: 2)
        }
    }

    private func wireServices() {
        location.onTick = { [weak self] fix in
            guard let self else { return }
            await self.engine.handleTick(fix: fix)
            self.background.syncRegions(rooms: self.engine.rooms,
                                        currentPosition: fix?.coordinate ?? self.location.lastFix?.coordinate)
        }
        background.onWake = { [weak self] in
            await self?.location.forceTick()
        }
        notifications.refreshAuthorizationState()
        location.start(intervalSeconds: settings.updateIntervalSeconds)
        background.start()
    }

    func updateIntervalChanged() {
        location.updateInterval(settings.updateIntervalSeconds)
    }

    // MARK: - Radio connection

    var mapStyle: (style: URL, attribution: String) {
        TileSourceResolver.resolve(kind: settings.tileSource,
                                   customTemplate: settings.customTileTemplate)
    }

    func startScanning() {
        ensureTransport()
        transport?.startScanning()
    }

    func stopScanning() {
        transport?.stopScanning()
    }

    func connect(to radio: DiscoveredRadio) async {
        guard !isConnecting, !transportState.isConnected else { return }
        isConnecting = true
        defer { isConnecting = false }
        ensureTransport()
        guard let transport else { return }
        userInitiatedDisconnect = false
        connectionError = nil
        do {
            try await transport.connect(to: radio.id)
            let session = MeshSession(transport: transport)
            self.session = session
            await session.start()
            let info = try await session.appStart()
            selfInfo = info
            engine.attach(session: session)
            location.attach(session: session)
            location.setRadioConnected(true)
            settings.lastRadioIdentifier = settings.demoMode ? nil : radio.id
            watchSessionEvents(session)
            deviceInfo = try? await session.queryDevice()
            batteryMilliVolts = try? await session.readBattery()
            startBatteryPolling()
            if settings.demoMode {
                engine.seedDemoRoomIfNeeded()
            }
            await location.forceTick()
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription
                ?? "Could not connect to the radio."
            // Tear the link down fully — a transport left connected with a
            // dead session would show a ghost radio in the dashboard.
            let failedSession = session
            session = nil
            Task { await failedSession?.stop() }
            transport.disconnect()
        }
    }

    /// Keeps the radio dashboard live (position refreshes, battery pushes).
    private func watchSessionEvents(_ session: MeshSession) {
        sessionEventTask?.cancel()
        sessionEventTask = Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .selfInfoUpdated(let info): self.selfInfo = info
                case .batteryUpdated(let mv): self.batteryMilliVolts = mv
                case .deviceInfoUpdated(let info): self.deviceInfo = info
                default: break
                }
            }
        }
    }

    /// Reconnects with backoff after an unexpected link drop (or at launch).
    private func scheduleReconnect(firstDelaySeconds: Double = 5) {
        guard reconnectTask == nil else { return }
        guard let targetID = settings.demoMode ? "demo-radio" : settings.lastRadioIdentifier else { return }
        reconnectTask = Task { [weak self] in
            defer { self?.reconnectTask = nil }
            for attempt in 0..<6 {
                let delay = attempt == 0
                    ? firstDelaySeconds
                    : min(60, 5 * Double(1 << attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.transportState.isConnected || self.userInitiatedDisconnect { return }
                await self.connect(to: DiscoveredRadio(id: targetID, name: "Saved radio", rssi: 0))
                if self.transportState.isConnected { return }
            }
        }
    }

    /// - Parameter forgetRadio: when true (a deliberate user disconnect),
    ///   drop the saved radio so the app stops trying to resume it. Internal
    ///   transitions (demo toggling) keep it.
    func disconnect(forgetRadio: Bool = true) {
        // Stays set until the next explicit connect — the disconnected state
        // event arrives asynchronously, after this method returns.
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        let closing = session
        Task { await closing?.stop() }
        sessionEventTask?.cancel()
        sessionEventTask = nil
        session = nil
        transport?.disconnect()
        engine.detachSession()
        location.attach(session: nil)
        location.setRadioConnected(false)
        selfInfo = nil
        deviceInfo = nil
        batteryMilliVolts = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        if forgetRadio {
            settings.lastRadioIdentifier = nil
        }
    }

    private func ensureTransport() {
        if transport == nil {
            installTransport(settings.demoMode ? SimulatedTransport() : BLETransport())
        }
    }

    private func installTransport(_ newTransport: MeshTransport) {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        transport?.disconnect()
        transport = newTransport

        streamTasks.append(Task { [weak self] in
            for await state in newTransport.states() {
                guard let self else { return }
                let wasConnected = self.transportState.isConnected
                self.transportState = state
                self.location.setRadioConnected(state.isConnected)
                if !state.isConnected {
                    self.selfInfo = nil
                }
                // Radios drop out on the trail all the time — get back on the
                // mesh without the user having to notice.
                if wasConnected, !state.isConnected, !self.userInitiatedDisconnect {
                    self.scheduleReconnect()
                }
            }
        })
        streamTasks.append(Task { [weak self] in
            for await list in newTransport.discovered() {
                self?.radios = list
            }
        })
    }

    private func startBatteryPolling() {
        batteryTimer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                self.batteryMilliVolts = try? await session.readBattery()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
    }

    // MARK: - Demo mode

    func enableDemoMode() async {
        settings.demoMode = true
        // Keep the saved real radio — the user is trying demo mode, not
        // forgetting their hardware.
        disconnect(forgetRadio: false)
        installTransport(SimulatedTransport())
        transport?.startScanning()
        try? await Task.sleep(nanoseconds: 900_000_000)
        if let radio = radios.first {
            await connect(to: radio)
        }
    }

    func disableDemoMode() {
        settings.demoMode = false
        disconnect(forgetRadio: false)
        engine.removeDemoRooms()
        installTransport(BLETransport())
        if settings.lastRadioIdentifier != nil {
            // Resume the real radio the user had before demo mode. The
            // disconnect above was ours, not the user's — clear the flag or
            // the reconnect loop will refuse to run.
            userInitiatedDisconnect = false
            scheduleReconnect(firstDelaySeconds: 2)
        }
    }
}
