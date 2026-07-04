import Foundation
import CoreLocation

/// Background wake-ups, done the way iOS actually allows (spec §4):
/// Significant Location Change plus CoreLocation region monitoring around
/// geofenced rooms. iOS caps monitored regions at 20 per app, so when a user
/// has more geofenced rooms than that, the nearest boundaries win and the set
/// is re-prioritized on every wake-up.
///
/// This is deliberately best-effort. Background detection lags by seconds to
/// minutes; all user-facing copy says "shortly after", never "instantly".
@MainActor
final class BackgroundMonitor: NSObject, ObservableObject {
    /// Head-room under the hard iOS limit of 20 regions.
    static let maxRegions = 18

    /// Called on any background trigger so the app can take a fresh GPS read
    /// and re-evaluate zone membership.
    var onWake: (() async -> Void)?

    private let manager = CLLocationManager()
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false // SLC/regions don't need it
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start() {
        guard !started else { return }
        guard manager.authorizationStatus == .authorizedAlways else { return }
        started = true
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        started = false
        manager.stopMonitoringSignificantLocationChanges()
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    /// Re-selects which room boundaries get one of the limited region slots.
    /// Priority: boundaries whose *edge* is nearest to the user right now —
    /// those are the ones that could plausibly fire next.
    func syncRegions(rooms: [Room], currentPosition: Coordinate?) {
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        struct Candidate {
            let roomID: String
            let center: Coordinate
            let radius: Double
            let edgeDistance: Double
        }

        let candidates: [Candidate] = rooms.compactMap { room in
            guard room.kind == .geofenced, let boundary = room.boundary else { return nil }
            let circle = GeoMath.enclosingCircle(of: boundary)
            let edge: Double
            if let currentPosition {
                edge = abs(GeoMath.distanceMeters(currentPosition, circle.center) - circle.radiusMeters)
            } else {
                edge = 0
            }
            return Candidate(roomID: room.id, center: circle.center,
                             radius: circle.radiusMeters, edgeDistance: edge)
        }
        .sorted { $0.edgeDistance < $1.edgeDistance }

        let selected = Array(candidates.prefix(Self.maxRegions))
        let wantedIDs = Set(selected.map { "fs-room-\($0.roomID)" })

        for region in manager.monitoredRegions where region.identifier.hasPrefix("fs-room-") {
            if !wantedIDs.contains(region.identifier) {
                manager.stopMonitoring(for: region)
            }
        }

        let existingIDs = Set(manager.monitoredRegions.map(\.identifier))
        for candidate in selected where !existingIDs.contains("fs-room-\(candidate.roomID)") {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: candidate.center.latitude,
                                               longitude: candidate.center.longitude),
                // Regions use the enclosing circle; precise containment is
                // re-checked in app code against the true boundary shape.
                radius: min(candidate.radius, manager.maximumRegionMonitoringDistance),
                identifier: "fs-room-\(candidate.roomID)")
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }
}

extension BackgroundMonitor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in await self.onWake?() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in await self.onWake?() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in await self.onWake?() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedAlways {
                self.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Region slots can fail transiently (e.g. over-limit races); the next
        // syncRegions pass repairs the set.
    }
}
