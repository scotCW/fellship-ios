import Foundation
import CoreLocation

/// Produces the app's single shared stream of location fixes.
///
/// Source of truth is the **radio's GPS** whenever a radio is connected and
/// reporting a plausible position; the phone's CoreLocation is the explicit
/// fallback (spec §4). One timer runs at the global update interval — every
/// consumer (all rooms' presence, "open to invite" beacons, the map) shares
/// each read. Nothing in the app polls GPS on its own schedule.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var lastFix: LocationFix?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Compass heading in degrees, for the locate-a-member view.
    @Published private(set) var headingDegrees: Double?

    /// Fires once per interval tick with the freshest fix (or nil when no
    /// source produced one). RoomEngine hangs presence broadcasting off this.
    var onTick: ((LocationFix?) async -> Void)?

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var meshSession: MeshSession?
    private var radioConnected = false
    private var lastPhoneLocation: CLLocation?
    private var intervalSeconds: TimeInterval = 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.pausesLocationUpdatesAutomatically = true
        authorization = manager.authorizationStatus
    }

    func attach(session: MeshSession?) {
        meshSession = session
    }

    func setRadioConnected(_ connected: Bool) {
        radioConnected = connected
        // The phone's GPS runs continuously only while it's the active
        // source; with radio GPS primary, keeping CoreLocation streaming
        // would just burn battery (spec §4's fallback is explicit).
        if connected {
            manager.stopUpdatingLocation()
        } else if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    var gpsSourceLabel: String {
        guard let lastFix else { return "No fix yet" }
        switch lastFix.source {
        case .radio: return "Radio GPS"
        case .phone: return "Phone GPS (fallback)"
        }
    }

    // MARK: - The one global timer

    func start(intervalSeconds: TimeInterval) {
        self.intervalSeconds = max(10, intervalSeconds)
        timer?.invalidate()
        if !radioConnected,
           authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
        let t = Timer(timeInterval: self.intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        t.tolerance = self.intervalSeconds * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await tick() } // immediate first read
    }

    func updateInterval(_ seconds: TimeInterval) {
        start(intervalSeconds: seconds)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
    }

    func startHeadingUpdates() {
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stopHeadingUpdates() {
        manager.stopUpdatingHeading()
        headingDegrees = nil
    }

    /// One shared GPS read: radio first, phone fallback (spec §4).
    private func tick() async {
        var fix: LocationFix?

        if radioConnected, let session = meshSession {
            if let info = try? await session.refreshSelfInfo(),
               info.advertCoordinate.isPlausible {
                fix = LocationFix(coordinate: info.advertCoordinate, source: .radio, timestamp: Date())
            }
        }

        if fix == nil, let phone = lastPhoneLocation,
           Date().timeIntervalSince(phone.timestamp) < max(intervalSeconds * 2, 120) {
            fix = LocationFix(coordinate: Coordinate(latitude: phone.coordinate.latitude,
                                                     longitude: phone.coordinate.longitude),
                              source: .phone, timestamp: phone.timestamp)
        }

        if let fix { lastFix = fix }
        await onTick?(fix)
    }

    /// Lets background wake-ups force an immediate re-read outside the timer.
    func forceTick() async {
        await tick()
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.setRadioConnected(self.radioConnected) // re-evaluate GPS source
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.lastPhoneLocation = latest
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.headingDegrees = degrees
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient CoreLocation errors are expected (e.g. kCLErrorLocationUnknown);
        // the next tick simply tries again.
    }
}
